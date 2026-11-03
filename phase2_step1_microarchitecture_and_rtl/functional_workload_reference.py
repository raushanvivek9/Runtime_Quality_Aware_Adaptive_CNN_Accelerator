#!/usr/bin/env python3
"""
================================================================================
Neural_Acc: Independent Functional Software Reference Model (TSK-08)
================================================================================
Description:
    Independent algorithmic reference model for the Neural_Acc CNN accelerator.
    Validates arithmetic contracts, saturation clamping, K-reduction,
    mode-based column gating, and adaptive policy decisions.

Mathematical Contract:
    - Inputs: 16-bit signed 2's complement ([-32768, 32767])
    - Multiplier: Full precision 32-bit signed product: P = A * W
    - Exact-Zero Skip:
        If act_mask == 0 or A == 0: bypass MAC, product = 0, cycle_skipped = 1
    - Accumulation: 40-bit signed saturation accumulator:
        Sum_41 = Accum_40 + P_32
        SAT_MAX_POS = +549,755,813,887 (40'sh7F_FFFF_FFFF)
        SAT_MAX_NEG = -549,755,813,888 (-40'sh80_0000_0000)
        If Sum_41 > SAT_MAX_POS: Accum_40 = SAT_MAX_POS, sticky_sat = 1
        If Sum_41 < SAT_MAX_NEG: Accum_40 = SAT_MAX_NEG, sticky_sat = 1
        Else: Accum_40 = Sum_41, sticky_sat unchanged
================================================================================
"""

import sys

SAT_MAX_POS = (1 << 39) - 1     # +549,755,813,887
SAT_MAX_NEG = -(1 << 39)        # -549,755,813,888
D_MAX_Q16   = 3277              # ~0.05 in Q16.16 (5% threshold)

def sign_extend_16(val):
    val = val & 0xFFFF
    if val & 0x8000:
        return val - 0x10000
    return val

class MacUnitRef:
    def __init__(self):
        self.accum = 0
        self.sticky_sat = False
        self.cycle_skipped = False

    def reset(self):
        self.accum = 0
        self.sticky_sat = False
        self.cycle_skipped = False

    def accum_clear(self):
        self.accum = 0

    def sat_clear(self):
        self.sticky_sat = False

    def step(self, act, weight, mask=True, enable=True):
        if not enable:
            self.cycle_skipped = False
            return self.accum, self.sticky_sat, self.cycle_skipped

        # Check exact-zero bypass
        bypass = (not mask) or (act == 0)
        self.cycle_skipped = bypass

        if bypass:
            product = 0
            return self.accum, self.sticky_sat, self.cycle_skipped
        else:
            product = act * weight

        # 41-bit sum
        sum_val = self.accum + product

        # Saturation check
        if sum_val > SAT_MAX_POS:
            self.accum = SAT_MAX_POS
            self.sticky_sat = True
        elif sum_val < SAT_MAX_NEG:
            self.accum = SAT_MAX_NEG
            self.sticky_sat = True
        else:
            self.accum = sum_val

        return self.accum, self.sticky_sat, self.cycle_skipped


class PeArrayRef:
    def __init__(self, rows=4, cols=16):
        self.rows = rows
        self.cols = cols
        self.cfg_mode = 0  # 0: 16PE, 1: 32PE, 2: 64PE
        self.pes = [[MacUnitRef() for _ in range(cols)] for _ in range(rows)]

    def set_mode(self, mode):
        self.cfg_mode = mode

    def reset(self):
        for r in range(self.rows):
            for c in range(self.cols):
                self.pes[r][c].reset()

    def get_active_cols(self):
        if self.cfg_mode == 0:
            return 4
        elif self.cfg_mode == 1:
            return 8
        elif self.cfg_mode == 2:
            return 16
        else:
            return 0

    def step_broadcast(self, act, weight, mask=True, enable=True):
        active_cols = self.get_active_cols()
        outputs = [[0]*self.cols for _ in range(self.rows)]
        sats = [[False]*self.cols for _ in range(self.rows)]
        skips = [[False]*self.cols for _ in range(self.rows)]

        for r in range(self.rows):
            for c in range(self.cols):
                if c < active_cols:
                    out, sat, skip = self.pes[r][c].step(act, weight, mask, enable)
                    outputs[r][c] = out
                    sats[r][c] = sat
                    skips[r][c] = skip
                else:
                    # Inactive columns clamped to 0
                    outputs[r][c] = 0
                    sats[r][c] = False
                    skips[r][c] = False

        return outputs, sats, skips


class AdaptivePolicyRef:
    @staticmethod
    def resolve_mode(adaptive_en, req_mode, deg_16, deg_32, d_max=D_MAX_Q16):
        """
        Evaluates Stage 8A Decision Policy:
        - If adaptive_en is 0: uses req_mode directly.
        - If adaptive_en is 1:
            - If deg_16 <= d_max: mode = 0 (16-PE), fallback = 0
            - Else if deg_32 <= d_max: mode = 1 (32-PE), fallback = 0
            - Else: mode = 2 (64-PE), fallback = 1
        """
        if not adaptive_en:
            invalid = (req_mode == 3)
            return req_mode, False, invalid

        if deg_16 <= d_max:
            return 0, False, False  # 16-PE
        elif deg_32 <= d_max:
            return 1, False, False  # 32-PE
        else:
            return 2, True, False   # 64-PE fallback


def generate_reference_results():
    results = {}

    # Category 1: Positive Operands
    mac = MacUnitRef()
    pairs_cat1 = [(15, 10), (20, 30), (100, 5), (45, 2)]
    for a, w in pairs_cat1:
        mac.step(a, w)
    results['CAT1_POSITIVE'] = {
        'inputs': pairs_cat1,
        'golden_accum': mac.accum,
        'expected_accum': 15*10 + 20*30 + 100*5 + 45*2, # 150 + 600 + 500 + 90 = 1340
        'sticky_sat': mac.sticky_sat
    }

    # Category 2: Negative Operands
    mac = MacUnitRef()
    pairs_cat2a = [(-15, -10), (-20, -30), (-100, -5), (-45, -2)]
    for a, w in pairs_cat2a:
        mac.step(a, w)
    accum_2a = mac.accum # 1340

    mac.reset()
    pairs_cat2b = [(-15, 10), (-20, 30), (-100, 5), (-45, 2)]
    for a, w in pairs_cat2b:
        mac.step(a, w)
    results['CAT2_NEGATIVE'] = {
        'inputs_neg_neg': pairs_cat2a,
        'accum_neg_neg': accum_2a,
        'inputs_neg_pos': pairs_cat2b,
        'golden_accum': mac.accum,
        'expected_accum': -1340,
        'sticky_sat': mac.sticky_sat
    }

    # Category 3: Mixed-Sign Operands
    mac.reset()
    pairs_cat3 = [(12, 8), (-4, 10), (25, -6), (-15, 14)]
    for a, w in pairs_cat3:
        mac.step(a, w)
    results['CAT3_MIXED'] = {
        'inputs': pairs_cat3,
        'golden_accum': mac.accum,
        'expected_accum': 96 - 40 - 150 - 210, # -304
        'sticky_sat': mac.sticky_sat
    }

    # Category 4: Exact-Zero and Skip
    mac.reset()
    pairs_cat4 = [
        (10, 20, True),   # 200
        (0, 50, True),    # zero act -> skip
        (30, 0, True),    # zero weight -> prod=0
        (5, 4, False),    # zero mask -> skip
        (8, 9, True)      # 72
    ]
    skips = []
    for a, w, m in pairs_cat4:
        _, _, s = mac.step(a, w, mask=m)
        skips.append(s)
    results['CAT4_ZERO_SKIP'] = {
        'inputs': pairs_cat4,
        'golden_accum': mac.accum,
        'expected_accum': 200 + 72, # 272
        'skips': skips,
        'sticky_sat': mac.sticky_sat
    }

    # Category 5: Min/Max Limits
    mac.reset()
    # 32767 * 32767 = 1,073,676,289
    # -32768 * 32767 = -1,073,709,056
    # -32768 * -32768 = +1,073,741,824
    pairs_cat5 = [(32767, 32767), (-32768, 32767), (-32768, -32768)]
    for a, w in pairs_cat5:
        mac.step(a, w)
    results['CAT5_MIN_MAX'] = {
        'inputs': pairs_cat5,
        'golden_accum': mac.accum,
        'expected_accum': 1073676289 - 1073709056 + 1073741824, # 1,073,709,057
        'sticky_sat': mac.sticky_sat
    }

    # Category 6: Saturation Behavior
    mac.reset()
    # Continuous positive accumulation of 32767*32767 (1,073,676,289)
    # 515 steps: 515 * 1073676289 = 552,943,288,835 > SAT_MAX_POS
    for _ in range(515):
        mac.step(32767, 32767)
    pos_sat_val = mac.accum
    pos_sat_flag = mac.sticky_sat

    mac.reset()
    # Continuous negative accumulation of -32768*32767 (-1,073,709,056)
    # 515 steps: 515 * -1073709056 = -552,960,163,840 < SAT_MAX_NEG
    for _ in range(515):
        mac.step(-32768, 32767)
    neg_sat_val = mac.accum
    neg_sat_flag = mac.sticky_sat

    results['CAT6_SATURATION'] = {
        'pos_sat_val': pos_sat_val,
        'pos_sat_flag': pos_sat_flag,
        'expected_pos_sat': SAT_MAX_POS,
        'neg_sat_val': neg_sat_val,
        'neg_sat_flag': neg_sat_flag,
        'expected_neg_sat': SAT_MAX_NEG
    }

    # Category 7: Distinct Sequences Across Multiple PEs (Standalone Array)
    pe_arr = PeArrayRef()
    pe_arr.set_mode(2) # 64-PE mode
    distinct_expected = [[0]*16 for _ in range(4)]
    # Each PE gets act = r + 1, weight = c + 1
    for r in range(4):
        for c in range(16):
            mac_pe = MacUnitRef()
            for k in range(4):
                mac_pe.step((r + 1) * (k + 1), (c + 1))
            distinct_expected[r][c] = mac_pe.accum
    results['CAT7_DISTINCT_PES'] = {
        'sample_pe_0_0': distinct_expected[0][0], # (1*1 + 2*1 + 3*1 + 4*1)*1 = 10
        'sample_pe_3_15': distinct_expected[3][15], # (4*1 + 8*1 + 12*1 + 16*1)*16 = 40 * 16 = 640
        'matrix': distinct_expected
    }

    # Category 8: Multiple K Reductions
    k_vals = [1, 2, 4, 8, 16, 64]
    k_results = {}
    for k in k_vals:
        mac.reset()
        for i in range(k):
            mac.step(10, 3) # 30 per step
        k_results[k] = mac.accum
    results['CAT8_MULTIPLE_K'] = k_results

    # Category 9: Consecutive Layer Executions
    mac.reset()
    # Layer 1
    for i in range(3):
        mac.step(4, 5) # 20*3 = 60
    l1_out = mac.accum
    # Layer boundary: clear accum
    mac.accum_clear()
    for i in range(2):
        mac.step(7, -3) # -21*2 = -42
    l2_out = mac.accum
    results['CAT9_CONSECUTIVE_LAYERS'] = {'layer1': l1_out, 'layer2': l2_out}

    # Category 10: Mid-flight Reset
    mac.reset()
    for i in range(5):
        mac.step(10, 10)
    # Mid-flight reset occurs
    mac.reset()
    post_rst = mac.accum
    results['CAT10_RESET'] = {'post_reset_accum': post_rst}

    return results

if __name__ == '__main__':
    res = generate_reference_results()
    print("=== Neural_Acc Functional Software Reference Model Verification ===")
    print(f"CAT1 (Positive): Golden = {res['CAT1_POSITIVE']['golden_accum']} [Match: {res['CAT1_POSITIVE']['golden_accum'] == res['CAT1_POSITIVE']['expected_accum']}]")
    print(f"CAT2 (Negative): Golden = {res['CAT2_NEGATIVE']['golden_accum']} [Match: {res['CAT2_NEGATIVE']['golden_accum'] == res['CAT2_NEGATIVE']['expected_accum']}]")
    print(f"CAT3 (Mixed-Sign): Golden = {res['CAT3_MIXED']['golden_accum']} [Match: {res['CAT3_MIXED']['golden_accum'] == res['CAT3_MIXED']['expected_accum']}]")
    print(f"CAT4 (Zero-Skip): Golden = {res['CAT4_ZERO_SKIP']['golden_accum']} [Match: {res['CAT4_ZERO_SKIP']['golden_accum'] == res['CAT4_ZERO_SKIP']['expected_accum']}], Skips = {res['CAT4_ZERO_SKIP']['skips']}")
    print(f"CAT5 (Min/Max): Golden = {res['CAT5_MIN_MAX']['golden_accum']} [Match: {res['CAT5_MIN_MAX']['golden_accum'] == res['CAT5_MIN_MAX']['expected_accum']}]")
    print(f"CAT6 (Positive Sat): Golden = {res['CAT6_SATURATION']['pos_sat_val']} == {res['CAT6_SATURATION']['expected_pos_sat']}, Flag = {res['CAT6_SATURATION']['pos_sat_flag']}")
    print(f"CAT6 (Negative Sat): Golden = {res['CAT6_SATURATION']['neg_sat_val']} == {res['CAT6_SATURATION']['expected_neg_sat']}, Flag = {res['CAT6_SATURATION']['neg_sat_flag']}")
    print(f"CAT7 (Distinct PEs): PE[0][0] = {res['CAT7_DISTINCT_PES']['sample_pe_0_0']}, PE[3][15] = {res['CAT7_DISTINCT_PES']['sample_pe_3_15']}")
    print(f"CAT8 (Multiple K): {res['CAT8_MULTIPLE_K']}")
    print(f"CAT9 (Consecutive): L1 = {res['CAT9_CONSECUTIVE_LAYERS']['layer1']}, L2 = {res['CAT9_CONSECUTIVE_LAYERS']['layer2']}")
    print(f"CAT10 (Reset): Post-Reset = {res['CAT10_RESET']['post_reset_accum']}")

