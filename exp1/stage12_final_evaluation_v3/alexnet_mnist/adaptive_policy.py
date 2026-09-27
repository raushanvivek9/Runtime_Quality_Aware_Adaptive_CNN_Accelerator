import math


RESOURCE_OPTIONS = (16, 32, 64)
EPSILONS = (0.0, 0.05, 0.10, 0.20)


def choose_pe(useful_macs, epsilon):
    baseline = math.ceil(useful_macs / 64)
    allowed = math.ceil(baseline * (1 + epsilon))
    for pe in RESOURCE_OPTIONS:
        if math.ceil(useful_macs / pe) <= allowed:
            return pe, baseline, math.ceil(useful_macs / pe), allowed
    return 64, baseline, baseline, allowed