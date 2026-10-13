// license:BSD-3-Clause
// copyright-holders:Aaron Giles
//
// Yamaha YMZ280B, as MAME's src/devices/sound/ymz280b.cpp plays it (0.289),
// cut to what this board uses and taken out of MAME's device framework, as
// the reference the board's chip is held against (sim/ymz280b).
//
// The voice logic is MAME's, line for line: ADPCM, 8- and 16-bit PCM, the
// loop, the end with its ramp to zero, the linear interpolation at twice the
// chip's rate (clock / 192), the pan and level. What MAME's framework
// supplied is explicit here:
//
//   * update(n) is MAME's sound_stream_update for n samples. MAME calls it
//     whenever the stream is brought up to date – before every register
//     write and status read, and on the sound manager's own updates – and the
//     ramp at a sample's end runs only to the end of the update it falls in,
//     so the caller decides where updates fall.
//   * The output is the mono speaker's sum as integers: for every sample,
//     the sum over voices of trunc(interp * lvol / 2) + trunc(interp * rvol
//     / 2), which MAME adds as floats over 32768 * 256 (both outputs routed
//     to the one speaker at 1.0). Divide by 256 for 16-bit samples.
//   * The end-of-sample IRQ, which MAME raises from a zero-time timer after
//     the update that found the end, is fire_timers(), for the caller to
//     call after the access that caused the update.
//   * The external memory port and the DSP registers are left out (not
//     wired on this board).

#pragma once
#include <cstdint>
#include <cstring>
#include <vector>

class ymz280b_mame {
public:
    static constexpr unsigned FRAC_BITS = 9;
    static constexpr int32_t  FRAC_ONE  = 1 << FRAC_BITS;
    static constexpr int MAX_SAMPLE_CHUNK = 10000;

    struct voice_t {
        uint8_t  playing = 0;
        bool     ended = false;
        uint8_t  keyon = 0;
        uint8_t  looping = 0;
        uint8_t  mode = 0;
        uint16_t fnum = 0;
        uint8_t  level = 0;
        uint8_t  pan = 0;
        uint32_t start = 0, stop = 0, loop_start = 0, loop_end = 0;
        uint32_t position = 0;
        int32_t  signal = 0, step = 0;
        int32_t  loop_signal = 0, loop_step = 0;
        uint32_t loop_count = 0;
        int32_t  output_left = 0, output_right = 0;
        int32_t  output_step = 0;
        int32_t  output_pos = 0;
        int16_t  last_sample = 0, curr_sample = 0;
        uint8_t  irq_schedule = 0;
    };

    voice_t  m_voice[8];
    uint8_t  m_current_register = 0;
    uint8_t  m_status_register = 0;
    uint8_t  m_irq_state = 0;
    uint8_t  m_irq_mask = 0;
    uint8_t  m_irq_enable = 0;
    uint8_t  m_keyon_enable = 0;

    const uint8_t* m_rom = nullptr;
    uint32_t m_rom_mask = 0;          // the ROM's size - 1 (a power of two)

    ymz280b_mame(const uint8_t* rom, uint32_t size) : m_rom(rom), m_rom_mask(size - 1) {
        for (int nib = 0; nib < 16; nib++) {
            int value = (nib & 0x07) * 2 + 1;
            diff_lookup[nib] = (nib & 0x08) ? -value : value;
        }
        m_scratch.resize(MAX_SAMPLE_CHUNK);
        reset();
    }

    void reset() {
        for (int i = 0xff; i >= 0; i--) { m_current_register = i; write_to_register(0); }
        m_current_register = 0;
        m_status_register = 0;
        for (auto& v : m_voice) {
            v.curr_sample = 0; v.last_sample = 0; v.output_pos = FRAC_ONE; v.playing = 0;
        }
    }

    // the 68000's side: offset 0 selects a register, 1 writes it
    void write(int offset, uint8_t data) {
        if ((offset & 1) == 0) m_current_register = data;
        else write_to_register(data);
    }
    uint8_t read_status() {
        uint8_t result = m_status_register;
        m_status_register = 0;
        update_irq_state();
        return result;
    }
    bool irq() const { return m_irq_state; }

    // MAME's sound_stream_update for n samples; out[i] gets the mono sum
    void update(int n, int64_t* out) {
        for (int i = 0; i < n; i++) out[i] = 0;
        for (int v = 0; v < 8; v++) {
            voice_t* voice = &m_voice[v];
            int16_t prev = voice->last_sample;
            int16_t curr = voice->curr_sample;
            int16_t* curr_data = m_scratch.data();
            int32_t sampindex = 0;
            uint32_t new_samples, samples_left;
            uint32_t final_pos;
            int remaining = n;
            int lvol = voice->output_left;
            int rvol = voice->output_right;

            if (!voice->playing && curr == 0 && prev == 0) {
                voice->output_pos = FRAC_ONE;
                continue;
            }

            while (remaining > 0 && voice->output_pos < FRAC_ONE) {
                int interp_sample = ((int32_t(prev) * (FRAC_ONE - voice->output_pos)) + (int32_t(curr) * voice->output_pos)) >> FRAC_BITS;
                out[sampindex] += interp_sample * lvol / 2 + interp_sample * rvol / 2;
                sampindex++;
                voice->output_pos += voice->output_step;
                remaining--;
            }
            if (voice->output_pos >= FRAC_ONE)
                voice->output_pos -= FRAC_ONE;
            else
                continue;

            final_pos = voice->output_pos + remaining * voice->output_step;
            new_samples = (final_pos + FRAC_ONE) >> FRAC_BITS;
            if (new_samples > MAX_SAMPLE_CHUNK)
                new_samples = MAX_SAMPLE_CHUNK;
            samples_left = new_samples;

            switch (voice->playing << 7 | voice->mode) {
                case 0x81: samples_left = generate_adpcm(voice, m_scratch.data(), new_samples); break;
                case 0x82: samples_left = generate_pcm8(voice, m_scratch.data(), new_samples); break;
                case 0x83: samples_left = generate_pcm16(voice, m_scratch.data(), new_samples); break;
                default:   samples_left = 0; memset(m_scratch.data(), 0, new_samples * sizeof(int16_t)); break;
            }

            if (samples_left || voice->ended) {
                voice->ended = false;
                int base = new_samples - samples_left;
                int i, t = (base == 0) ? curr : m_scratch[base - 1];
                for (i = 0; i < (int)samples_left; i++) {
                    if (t < 0) t = -((-t * 15) >> 4);
                    else if (t > 0) t = (t * 15) >> 4;
                    m_scratch[base + i] = t;
                }
                if (base != 0) {
                    voice->playing = 0;
                    voice->irq_schedule = 1;
                }
            }

            prev = curr;
            curr = *curr_data++;

            while (remaining > 0) {
                while (remaining > 0 && voice->output_pos < FRAC_ONE) {
                    int interp_sample = ((int32_t(prev) * (FRAC_ONE - voice->output_pos)) + (int32_t(curr) * voice->output_pos)) >> FRAC_BITS;
                    out[sampindex] += interp_sample * lvol / 2 + interp_sample * rvol / 2;
                    sampindex++;
                    voice->output_pos += voice->output_step;
                    remaining--;
                }
                if (voice->output_pos >= FRAC_ONE) {
                    voice->output_pos -= FRAC_ONE;
                    prev = curr;
                    curr = *curr_data++;
                }
            }
            voice->last_sample = prev;
            voice->curr_sample = curr;
        }
    }

    // MAME raises a found end from a zero-time timer, so the access that
    // brought the stream up to date (a status read sees the status from
    // before the update's ends; a key on or off cancels its voice's) runs
    // first: call this after it, or after an update of the sound manager's own
    void fire_timers() {
        for (int v = 0; v < 8; v++) {
            voice_t* voice = &m_voice[v];
            if (!voice->irq_schedule) continue;
            voice->playing = 0;
            m_status_register |= 1 << v;
            update_irq_state();
            voice->irq_schedule = 0;
        }
    }

private:
    int diff_lookup[16];
    static constexpr int index_scale[8] = { 0x0e6, 0x0e6, 0x0e6, 0x0e6, 0x133, 0x199, 0x200, 0x266 };
    std::vector<int16_t> m_scratch;

    uint8_t read_byte(uint32_t a) const { return m_rom[a & m_rom_mask]; }

    void update_irq_state() {
        int irq_bits = m_status_register & m_irq_mask;
        if (!m_irq_enable) irq_bits = 0;
        m_irq_state = irq_bits ? 1 : 0;
    }

    void update_step(voice_t* voice) {
        int frequency = (voice->mode == 1) ? (voice->fnum & 0x0ff) : (voice->fnum & 0x1ff);
        voice->output_step = frequency + 1;
    }

    void update_volumes(voice_t* voice) {
        if (voice->pan == 8) {
            voice->output_left = voice->level;
            voice->output_right = voice->level;
        } else if (voice->pan < 8) {
            voice->output_left = voice->level;
            voice->output_right = (voice->pan == 0) ? 0 : voice->level * (voice->pan - 1) / 7;
        } else {
            voice->output_left = voice->level * (15 - voice->pan) / 7;
            voice->output_right = voice->level;
        }
    }

    int generate_adpcm(voice_t* voice, int16_t* buffer, int samples) {
        int position = voice->position;
        int signal = voice->signal;
        int step = voice->step;
        int val;
        if (!voice->looping) {
            while (samples) {
                val = read_byte(position / 2) >> ((~position & 1) << 2);
                signal += (step * diff_lookup[val & 15]) / 8;
                if (signal > 32767) signal = 32767;
                else if (signal < -32768) signal = -32768;
                step = (step * index_scale[val & 7]) >> 8;
                if (step > 0x6000) step = 0x6000;
                else if (step < 0x7f) step = 0x7f;
                *buffer++ = signal;
                samples--;
                position++;
                if (position >= (int)voice->stop) { voice->ended = true; break; }
            }
        } else {
            while (samples) {
                val = read_byte(position / 2) >> ((~position & 1) << 2);
                signal += (step * diff_lookup[val & 15]) / 8;
                if (signal > 32767) signal = 32767;
                else if (signal < -32768) signal = -32768;
                step = (step * index_scale[val & 7]) >> 8;
                if (step > 0x6000) step = 0x6000;
                else if (step < 0x7f) step = 0x7f;
                *buffer++ = signal;
                samples--;
                position++;
                if (position == (int)voice->loop_start && voice->loop_count == 0) {
                    voice->loop_signal = signal;
                    voice->loop_step = step;
                }
                if (position >= (int)voice->loop_end) {
                    if (voice->keyon) {
                        position = voice->loop_start;
                        signal = voice->loop_signal;
                        step = voice->loop_step;
                        voice->loop_count++;
                    }
                }
                if (position >= (int)voice->stop) { voice->ended = true; break; }
            }
        }
        voice->position = position;
        voice->signal = signal;
        voice->step = step;
        return samples;
    }

    int generate_pcm8(voice_t* voice, int16_t* buffer, int samples) {
        int position = voice->position;
        int val;
        while (samples) {
            val = read_byte(position / 2);
            *buffer++ = (int8_t)val * 256;
            samples--;
            position += 2;
            if (voice->looping && position >= (int)voice->loop_end && voice->keyon)
                position = voice->loop_start;
            if (position >= (int)voice->stop) { voice->ended = true; break; }
        }
        voice->position = position;
        return samples;
    }

    int generate_pcm16(voice_t* voice, int16_t* buffer, int samples) {
        int position = voice->position;
        int val;
        while (samples) {
            val = (int16_t)((read_byte(position / 2 + 1) << 8) + read_byte(position / 2 + 0));
            *buffer++ = val;
            samples--;
            position += 4;
            if (voice->looping && position >= (int)voice->loop_end && voice->keyon)
                position = voice->loop_start;
            if (position >= (int)voice->stop) { voice->ended = true; break; }
        }
        voice->position = position;
        return samples;
    }

    void write_to_register(int data) {
        if (m_current_register < 0x80) {
            voice_t* voice = &m_voice[(m_current_register >> 2) & 7];
            switch (m_current_register & 0xe3) {
                case 0x00:
                    voice->fnum = (voice->fnum & 0x100) | (data & 0xff);
                    update_step(voice);
                    break;
                case 0x01:
                    voice->fnum = (voice->fnum & 0xff) | ((data & 0x01) << 8);
                    voice->looping = (data & 0x10) >> 4;
                    if ((data & 0x60) == 0)
                        data &= 0x7f;
                    else
                        voice->mode = (data & 0x60) >> 5;
                    if (!voice->keyon && (data & 0x80) && m_keyon_enable) {
                        voice->playing = 1;
                        voice->position = voice->start;
                        voice->signal = voice->loop_signal = 0;
                        voice->step = voice->loop_step = 0x7f;
                        voice->loop_count = 0;
                        voice->irq_schedule = 0;
                    } else if (voice->keyon && !(data & 0x80)) {
                        voice->playing = 0;
                        voice->irq_schedule = 0;
                    }
                    voice->keyon = (data & 0x80) >> 7;
                    update_step(voice);
                    break;
                case 0x02: voice->level = data; update_volumes(voice); break;
                case 0x03: voice->pan = data & 0x0f; update_volumes(voice); break;
                case 0x20: voice->start      = (voice->start      & (0x00ffff << 1)) | (data << 17); break;
                case 0x21: voice->loop_start = (voice->loop_start & (0x00ffff << 1)) | (data << 17); break;
                case 0x22: voice->loop_end   = (voice->loop_end   & (0x00ffff << 1)) | (data << 17); break;
                case 0x23: voice->stop       = (voice->stop       & (0x00ffff << 1)) | (data << 17); break;
                case 0x40: voice->start      = (voice->start      & (0xff00ff << 1)) | (data << 9); break;
                case 0x41: voice->loop_start = (voice->loop_start & (0xff00ff << 1)) | (data << 9); break;
                case 0x42: voice->loop_end   = (voice->loop_end   & (0xff00ff << 1)) | (data << 9); break;
                case 0x43: voice->stop       = (voice->stop       & (0xff00ff << 1)) | (data << 9); break;
                case 0x60: voice->start      = (voice->start      & (0xffff00 << 1)) | (data << 1); break;
                case 0x61: voice->loop_start = (voice->loop_start & (0xffff00 << 1)) | (data << 1); break;
                case 0x62: voice->loop_end   = (voice->loop_end   & (0xffff00 << 1)) | (data << 1); break;
                case 0x63: voice->stop       = (voice->stop       & (0xffff00 << 1)) | (data << 1); break;
                default: break;
            }
        } else {
            switch (m_current_register) {
                case 0xfe:
                    m_irq_mask = data;
                    update_irq_state();
                    break;
                case 0xff:
                    m_irq_enable = (data & 0x10) >> 4;
                    update_irq_state();
                    if (m_keyon_enable && !(data & 0x80)) {
                        for (auto& v : m_voice) { v.playing = 0; v.irq_schedule = 0; }
                    } else if (!m_keyon_enable && (data & 0x80)) {
                        for (auto& v : m_voice)
                            if (v.keyon && v.looping) v.playing = 1;
                    }
                    m_keyon_enable = (data & 0x80) >> 7;
                    break;
                default: break;
            }
        }
    }
};
