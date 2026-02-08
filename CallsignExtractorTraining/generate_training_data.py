#!/usr/bin/env python3
"""Generate synthetic amateur radio QSO training data for callsign extraction.

Produces labeled examples of decoded digital mode text (RTTY, PSK31, etc.)
with the target callsign identified — the station the user would want to work.
"""

import csv
import random
import string
import os

random.seed(42)

# ---------------------------------------------------------------------------
# Callsign generation helpers
# ---------------------------------------------------------------------------

# Common amateur radio prefixes by region
PREFIXES = [
    # USA
    "W", "K", "N", "AA", "AB", "AC", "AD", "AE", "AF", "AG", "AI", "AJ", "AK", "AL",
    "KA", "KB", "KC", "KD", "KE", "KF", "KG", "KI", "KJ", "KK", "KN", "KO",
    "KQ", "KR", "KS", "KT", "KU", "KV", "KW", "KX", "KY", "KZ",
    "NA", "NB", "NC", "ND", "NE", "NF", "NG", "NI", "NJ", "NK", "NL", "NM", "NN",
    "NO", "NP", "NQ", "NR", "NS", "NT", "NU", "NV", "NW", "NX", "NY", "NZ",
    "WA", "WB", "WC", "WD", "WE", "WF", "WG", "WI", "WJ", "WK", "WL", "WM",
    "WN", "WO", "WP", "WQ", "WR", "WS", "WT", "WU", "WV", "WW", "WX", "WY", "WZ",
    # Canada
    "VA", "VE", "VY",
    # UK
    "G", "M", "GW", "GM", "GI", "GD", "GU", "GJ",
    # Germany
    "DA", "DB", "DC", "DD", "DE", "DF", "DG", "DH", "DI", "DJ", "DK", "DL", "DM",
    # France
    "F",
    # Netherlands
    "PA", "PB", "PD", "PE", "PH", "PI",
    # Belgium
    "ON",
    # Italy
    "I", "IK", "IZ", "IU",
    # Spain
    "EA", "EB", "EC", "ED",
    # Japan
    "JA", "JE", "JF", "JG", "JH", "JI", "JJ", "JK", "JL", "JM",
    "JN", "JO", "JP", "JQ", "JR", "JS",
    # Australia
    "VK",
    # New Zealand
    "ZL",
    # Brazil
    "PP", "PQ", "PR", "PS", "PT", "PU", "PV", "PW", "PX", "PY",
    # South Africa
    "ZR", "ZS", "ZT", "ZU",
    # Russia
    "RA", "RB", "RC", "RD", "RE", "RF", "RG", "RK", "RL", "RM", "RN", "RO",
    "RT", "RU", "RV", "RW", "RX", "RZ", "UA", "UB", "UC", "UD",
    # India
    "VU",
    # China
    "BA", "BD", "BG", "BT", "BV", "BY",
    # South Korea
    "DS", "DT", "HL",
    # Argentina
    "LU", "LW",
    # Mexico
    "XE", "XF",
    # Sweden
    "SA", "SB", "SC", "SD", "SE", "SF", "SG", "SH", "SI", "SJ", "SK", "SL", "SM",
    # Finland
    "OF", "OG", "OH", "OI",
    # Czech Republic
    "OK", "OL",
    # Poland
    "SP", "SQ", "SR",
    # Portugal
    "CT", "CS",
    # Switzerland
    "HB",
    # Austria
    "OE",
]


def random_callsign() -> str:
    """Generate a realistic amateur radio callsign."""
    prefix = random.choice(PREFIXES)
    digit = str(random.randint(0, 9))
    suffix_len = random.randint(1, 3)
    suffix = "".join(random.choices(string.ascii_uppercase, k=suffix_len))
    return f"{prefix}{digit}{suffix}"


def random_rst() -> str:
    """Generate a random RST report."""
    return random.choice(["599", "579", "559", "589", "569", "549", "539", "529", "519"])


def random_name() -> str:
    names = [
        "JOHN", "MIKE", "BOB", "JIM", "TOM", "BILL", "DAVE", "STEVE", "RICK", "DAN",
        "PAUL", "MARK", "GARY", "PETE", "RON", "BRUCE", "ALAN", "TONY", "JEFF", "GREG",
        "RAY", "KEN", "FRANK", "JOE", "ED", "GEORGE", "LARRY", "DON", "JACK", "HARRY",
        "FRED", "ART", "WALT", "CHUCK", "ROGER", "CARL", "RALPH", "SAM", "LEE", "BEN",
        "YURI", "HANS", "LARS", "JEAN", "TARO", "KENJI", "PEDRO", "CARLOS", "AHMED",
        "IVAN", "OLGA", "ANNA", "MARIA", "LISA", "EMMA", "YUKI", "HIRO", "SVEN", "ERIK",
    ]
    return random.choice(names)


def random_qth() -> str:
    qths = [
        "CT", "MA", "NH", "NY", "NJ", "PA", "FL", "TX", "CA", "WA", "OR", "OH", "IL",
        "GA", "VA", "NC", "MI", "MN", "WI", "CO", "AZ", "LONDON", "BERLIN", "PARIS",
        "TOKYO", "SYDNEY", "MELBOURNE", "AUCKLAND", "MOSCOW", "ROME", "MADRID",
        "MUNICH", "HAMBURG", "STOCKHOLM", "HELSINKI", "OSLO", "PRAGUE", "WARSAW",
        "SAO PAULO", "BUENOS AIRES", "CAPE TOWN", "SEOUL", "BEIJING", "DELHI",
    ]
    return random.choice(qths)


def random_state() -> str:
    states = [
        "AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "FL", "GA", "HI", "ID", "IL",
        "IN", "IA", "KS", "KY", "LA", "ME", "MD", "MA", "MI", "MN", "MS", "MO", "MT",
        "NE", "NV", "NH", "NJ", "NM", "NY", "NC", "ND", "OH", "OK", "OR", "PA", "RI",
        "SC", "SD", "TN", "TX", "UT", "VT", "VA", "WA", "WV", "WI", "WY",
    ]
    return random.choice(states)


def random_park() -> str:
    """Generate a POTA/SOTA park/summit reference."""
    kind = random.choice(["K", "VE", "VK", "G", "DL", "JA", "ZL"])
    num = random.randint(1, 9999)
    return f"{kind}-{num:04d}"


def add_noise(text: str, noise_level: float = 0.0) -> str:
    """Simulate decode errors by randomly corrupting characters."""
    if noise_level <= 0:
        return text
    result = []
    for ch in text:
        r = random.random()
        if r < noise_level * 0.3:
            # drop character
            continue
        elif r < noise_level * 0.5:
            # replace with random character
            result.append(random.choice(string.ascii_uppercase + string.digits + " "))
        elif r < noise_level * 0.6:
            # duplicate character
            result.append(ch)
            result.append(ch)
        else:
            result.append(ch)
    return "".join(result)


# ---------------------------------------------------------------------------
# QSO template generators
# Each returns (text, target_callsign)
# ---------------------------------------------------------------------------

def gen_cq_basic(noise: float) -> tuple[str, str]:
    """CQ CQ CQ DE W1AW W1AW K"""
    target = random_callsign()
    n_cq = random.randint(1, 4)
    reps = random.randint(1, 3)
    cq_part = " ".join(["CQ"] * n_cq)
    call_part = " ".join([target] * reps)
    end = random.choice(["K", "KN", "K K", ""])
    text = f"{cq_part} DE {call_part} {end}".strip()
    return add_noise(text, noise), target


def gen_cq_no_de(noise: float) -> tuple[str, str]:
    """CQ CQ W1AW W1AW K  (no DE)"""
    target = random_callsign()
    n_cq = random.randint(1, 3)
    reps = random.randint(1, 2)
    cq_part = " ".join(["CQ"] * n_cq)
    call_part = " ".join([target] * reps)
    end = random.choice(["K", "KN", "K K", ""])
    text = f"{cq_part} {call_part} {end}".strip()
    return add_noise(text, noise), target


def gen_cq_pota(noise: float) -> tuple[str, str]:
    """CQ POTA CQ POTA DE K4SWL K4SWL K"""
    target = random_callsign()
    tag = random.choice(["POTA", "SOTA", "WWFF", "IOTA"])
    n_cq = random.randint(1, 3)
    reps = random.randint(1, 2)
    cq_part = " ".join([f"CQ {tag}"] * n_cq)
    call_part = " ".join([target] * reps)
    de = random.choice(["DE", ""])
    end = random.choice(["K", "KN", ""])
    text = f"{cq_part} {de} {call_part} {end}".strip()
    return add_noise(text, noise), target


def gen_cq_contest(noise: float) -> tuple[str, str]:
    """CQ TEST W1AW W1AW"""
    target = random_callsign()
    tag = random.choice(["TEST", "CONTEST", "CQ", "DX"])
    n_reps = random.randint(1, 3)
    reps = " ".join([target] * n_reps)
    cq_start = random.choice(["CQ", "CQ CQ", "CQ CQ CQ"])
    text = f"{cq_start} {tag} {reps}"
    return add_noise(text, noise), target


def gen_reply_to_cq(noise: float) -> tuple[str, str]:
    """W1AW W1AW DE VK3ABC VK3ABC K — target is W1AW (the CQ caller)."""
    target = random_callsign()
    caller = random_callsign()
    while caller == target:
        caller = random_callsign()
    t_reps = random.randint(1, 2)
    c_reps = random.randint(1, 2)
    t_part = " ".join([target] * t_reps)
    c_part = " ".join([caller] * c_reps)
    end = random.choice(["K", "KN", "K K", ""])
    text = f"{t_part} DE {c_part} {end}".strip()
    return add_noise(text, noise), target


def gen_reply_no_de(noise: float) -> tuple[str, str]:
    """W1AW VK3ABC K — target is W1AW (first callsign, being called)."""
    target = random_callsign()
    caller = random_callsign()
    while caller == target:
        caller = random_callsign()
    end = random.choice(["K", "KN", ""])
    text = f"{target} {caller} {end}".strip()
    return add_noise(text, noise), target


def gen_exchange(noise: float) -> tuple[str, str]:
    """VK3ABC DE W1AW UR RST 599 NAME JOHN QTH CT BK — target is W1AW (sending station / CQ caller context)."""
    target = random_callsign()
    other = random_callsign()
    while other == target:
        other = random_callsign()
    rst = random_rst()
    name = random_name()
    qth = random_qth()
    parts = [f"{other} DE {target}"]
    parts.append(f"UR RST {rst} {rst}")
    if random.random() > 0.3:
        parts.append(f"NAME {name}")
    if random.random() > 0.3:
        parts.append(f"QTH {qth}")
    end = random.choice(["BK", "K", "KN", "BTU", ""])
    parts.append(end)
    text = " ".join(parts).strip()
    return add_noise(text, noise), target


def gen_contest_exchange(noise: float) -> tuple[str, str]:
    """W1AW 599 CT — target is W1AW."""
    target = random_callsign()
    rst = random_rst()
    extra = random.choice([random_state(), str(random.randint(1, 40)), random_qth()])
    text = f"{target} {rst} {extra}"
    return add_noise(text, noise), target


def gen_pota_spot(noise: float) -> tuple[str, str]:
    """CQ POTA K4SWL K-1234 K — target is the activator callsign."""
    target = random_callsign()
    park = random_park()
    tag = random.choice(["POTA", "SOTA", "WWFF"])
    n_cq = random.randint(1, 2)
    cq_part = " ".join([f"CQ {tag}"] * n_cq)
    de = random.choice(["DE ", ""])
    end = random.choice(["K", "KN", ""])
    text = f"{cq_part} {de}{target} {park} {end}".strip()
    return add_noise(text, noise), target


def gen_long_qso_fragment(noise: float) -> tuple[str, str]:
    """Longer fragment with exchange details — target is the DE station."""
    target = random_callsign()
    other = random_callsign()
    while other == target:
        other = random_callsign()
    rst = random_rst()
    name = random_name()
    qth = random_qth()
    parts = []
    if random.random() > 0.5:
        parts.append(f"{other} DE {target} {target}")
    else:
        parts.append(f"{other} DE {target}")
    parts.append(f"GE OM TNX FER CALL")
    parts.append(f"UR RST {rst} {rst}")
    parts.append(f"NAME HR IS {name} {name}")
    parts.append(f"QTH IS {qth}")
    if random.random() > 0.5:
        parts.append(f"RIG IS ICOM")
    if random.random() > 0.5:
        parts.append(f"ANT IS DIPOLE")
    parts.append(f"HW CPY? {other} DE {target} KN")
    text = " ".join(parts)
    return add_noise(text, noise), target


def gen_tail_end(noise: float) -> tuple[str, str]:
    """73 fragment — target is the DE station."""
    target = random_callsign()
    other = random_callsign()
    while other == target:
        other = random_callsign()
    seventy_three = random.choice(["73", "73 73", "TU 73", "HPE CU AGN 73"])
    text = f"{seventy_three} {other} DE {target} SK"
    return add_noise(text, noise), target


def gen_cq_dx(noise: float) -> tuple[str, str]:
    """CQ DX CQ DX DE W1AW K"""
    target = random_callsign()
    n_cq = random.randint(1, 3)
    cq_part = " ".join(["CQ DX"] * n_cq)
    reps = random.randint(1, 2)
    call_part = " ".join([target] * reps)
    end = random.choice(["K", "KN", ""])
    text = f"{cq_part} DE {call_part} {end}".strip()
    return add_noise(text, noise), target


def gen_cq_with_freq(noise: float) -> tuple[str, str]:
    """CQ CQ DE W1AW W1AW PSE K — with frequency/mode mentions."""
    target = random_callsign()
    n_cq = random.randint(1, 3)
    cq_part = " ".join(["CQ"] * n_cq)
    reps = random.randint(1, 2)
    call_part = " ".join([target] * reps)
    extra = random.choice(["PSE K", "UP 1", "QSX 14070", "PSE QRZ", "K"])
    text = f"{cq_part} DE {call_part} {extra}".strip()
    return add_noise(text, noise), target


def gen_partial_decode_cq(noise: float) -> tuple[str, str]:
    """Simulates partial decode where CQ is garbled but callsign follows DE."""
    target = random_callsign()
    # Garble the CQ part
    garble = random.choice(["C ", "CQ C", " Q CQ", "C  CQ", "  CQ"])
    reps = random.randint(1, 2)
    call_part = " ".join([target] * reps)
    text = f"{garble} DE {call_part} K"
    return add_noise(text, noise), target


def gen_multi_exchange_buffer(noise: float) -> tuple[str, str]:
    """A buffer with the end of one QSO and start of a new CQ — target is the new CQ station."""
    old_call1 = random_callsign()
    old_call2 = random_callsign()
    target = random_callsign()
    while target in (old_call1, old_call2):
        target = random_callsign()

    # End of previous QSO
    prev_end = f"73 {old_call1} DE {old_call2} SK"
    # New CQ
    n_cq = random.randint(1, 3)
    cq_part = " ".join(["CQ"] * n_cq)
    reps = random.randint(1, 2)
    call_part = " ".join([target] * reps)
    new_cq = f"{cq_part} DE {call_part} K"

    text = f"{prev_end}  {new_cq}"
    return add_noise(text, noise), target


# ---------------------------------------------------------------------------
# Main data generation
# ---------------------------------------------------------------------------

GENERATORS = [
    (gen_cq_basic, 25),
    (gen_cq_no_de, 8),
    (gen_cq_pota, 15),
    (gen_cq_contest, 10),
    (gen_reply_to_cq, 10),
    (gen_reply_no_de, 4),
    (gen_exchange, 8),
    (gen_contest_exchange, 5),
    (gen_pota_spot, 8),
    (gen_long_qso_fragment, 5),
    (gen_tail_end, 4),
    (gen_cq_dx, 6),
    (gen_cq_with_freq, 5),
    (gen_partial_decode_cq, 4),
    (gen_multi_exchange_buffer, 3),
]

TOTAL_SAMPLES = 15000


def main():
    # Normalize weights
    total_weight = sum(w for _, w in GENERATORS)
    samples_per_gen = [(gen, int(TOTAL_SAMPLES * w / total_weight)) for gen, w in GENERATORS]

    # Noise levels: most clean, some moderate noise, a few heavy noise
    noise_distribution = [0.0] * 60 + [0.02] * 15 + [0.05] * 10 + [0.08] * 8 + [0.12] * 5 + [0.18] * 2

    data = []
    for gen, count in samples_per_gen:
        for _ in range(count):
            noise = random.choice(noise_distribution)
            text, target = gen(noise)
            # Clean up extra spaces
            text = " ".join(text.split())
            if target and text:
                data.append((text, target))

    # Top up if needed
    while len(data) < TOTAL_SAMPLES:
        gen, _ = random.choice(GENERATORS)
        noise = random.choice(noise_distribution)
        text, target = gen(noise)
        text = " ".join(text.split())
        if target and text:
            data.append((text, target))

    random.shuffle(data)

    out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "training_data.csv")
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["text", "target_callsign"])
        for text, target in data:
            writer.writerow([text, target])

    print(f"Generated {len(data)} training samples -> {out_path}")

    # Print a few examples
    print("\nExample samples:")
    for text, target in data[:15]:
        print(f"  [{target:>8s}] {text}")


if __name__ == "__main__":
    main()
