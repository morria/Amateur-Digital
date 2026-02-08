#!/usr/bin/env python3
"""Generate synthetic training data for HamTextClassifier."""

import csv
import math
import os
import random
import string

SEED = 42
TOTAL_LEGIT = 50_000
TOTAL_GARBAGE = 50_000
TRAIN_RATIO = 0.8

# --- Ham radio data building blocks ---

LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
DIGITS = "0123456789"

US_PREFIXES = [
    "W", "K", "N", "WA", "WB", "WD", "KA", "KB", "KC", "KD", "KE", "KF",
    "KG", "KI", "KJ", "KK", "KN", "NX", "AA", "AB", "AC", "AD", "AE", "AF",
    "AG", "AI", "AJ", "AK", "AL",
]
DX_PREFIXES = [
    "VE", "VA", "VK", "ZL", "G", "GM", "GW", "GI", "F", "DL", "DJ", "DK",
    "PA", "ON", "OZ", "SM", "OH", "LA", "EA", "I", "CT", "YU", "HA", "OK",
    "SP", "UR", "UA", "JA", "JH", "JR", "HL", "BV", "VU", "ZS", "PY", "LU",
    "CE", "XE", "TI", "HP", "HK", "YV", "HC", "OA", "CP",
]

CITIES = [
    "NEW YORK", "LOS ANGELES", "CHICAGO", "HOUSTON", "DALLAS", "DENVER",
    "SEATTLE", "PORTLAND", "MIAMI", "ATLANTA", "BOSTON", "TORONTO", "LONDON",
    "BERLIN", "PARIS", "TOKYO", "SYDNEY", "AUCKLAND", "SAO PAULO", "MOSCOW",
    "STOCKHOLM", "OSLO", "MADRID", "ROME", "VIENNA", "PRAGUE", "WARSAW",
    "BUDAPEST", "HELSINKI", "COPENHAGEN", "AMSTERDAM", "BRUSSELS", "LISBON",
    "CAPE TOWN", "MUMBAI", "BEIJING", "SEOUL", "TAIPEI", "MANILA", "JAKARTA",
    "SPRINGFIELD", "FAIRVIEW", "CLINTON", "FRANKLIN", "GREENVILLE", "BRISTOL",
    "MADISON", "CHESTER", "MARION", "GEORGETOWN",
]

NAMES = [
    "JOHN", "BOB", "MIKE", "JIM", "TOM", "BILL", "DAVE", "STEVE", "RICK",
    "DAN", "FRANK", "GEORGE", "PAUL", "MARK", "JEFF", "SCOTT", "GARY", "RON",
    "LARRY", "ED", "JOE", "PETE", "JACK", "RAY", "CARL", "AL", "FRED", "ART",
    "TONY", "LEE", "WAYNE", "BRUCE", "DON", "HAROLD", "ROGER", "RALPH",
    "HOWARD", "KEN", "DENNIS", "JERRY", "TERRY", "DOUG", "HENRY", "WALTER",
    "SAM", "ANDY", "CHRIS", "BRIAN", "KEVIN", "ERIC",
]

NAMES_MIXED = [n.capitalize() for n in NAMES]

RIGS = [
    "IC-7300", "IC-7610", "IC-9700", "IC-7851", "IC-705",
    "FT-991A", "FTDX10", "FTDX101D", "FT-710", "FT-891",
    "TS-890S", "TS-590SG", "TS-990S", "TS-480",
    "K3S", "K4", "KX3", "KX2", "K2",
    "FLEX-6600", "FLEX-6400", "FLEX-6700",
    "SDR", "QRP RIG", "HOMEBREW",
]

ANTENNAS = [
    "DIPOLE", "3 EL YAGI", "4 EL YAGI", "5 EL YAGI", "VERTICAL",
    "G5RV", "END FED", "EFHW", "LOOP", "QUAD", "HEX BEAM",
    "COBWEB", "WIRE ANTENNA", "LONG WIRE", "INVERTED V",
    "WINDOM", "OCF DIPOLE", "BEAM", "LOG PERIODIC", "DISCONE",
    "DELTA LOOP", "MAGNETIC LOOP", "BUDDIPOLE", "SCREWDRIVER",
]

BANDS = [
    "160M", "80M", "60M", "40M", "30M", "20M", "17M", "15M", "12M", "10M",
    "6M", "2M", "70CM",
]

WX_CONDITIONS = [
    "SUNNY", "CLOUDY", "RAINY", "SNOWY", "WINDY", "CLEAR", "OVERCAST",
    "FOGGY", "WARM", "COLD", "HOT", "MILD",
]

GRID_LETTERS_1 = "ABCDEFGHIJKLMNOR"
GRID_LETTERS_2 = "ABCDEFGHIJKLMNOPQRSTUVWX"


def random_callsign():
    """Generate a realistic amateur radio callsign."""
    if random.random() < 0.6:
        prefix = random.choice(US_PREFIXES)
        digit = random.choice(DIGITS[1:])
        suffix_len = random.randint(1, 3)
        suffix = "".join(random.choices(LETTERS, k=suffix_len))
        return f"{prefix}{digit}{suffix}"
    else:
        prefix = random.choice(DX_PREFIXES)
        digit = random.choice(DIGITS)
        suffix_len = random.randint(1, 3)
        suffix = "".join(random.choices(LETTERS, k=suffix_len))
        return f"{prefix}{digit}{suffix}"


def random_grid():
    """Generate a Maidenhead grid locator (4 or 6 chars)."""
    g1 = random.choice(GRID_LETTERS_1)
    g2 = random.choice(GRID_LETTERS_1)
    g3 = random.choice(DIGITS)
    g4 = random.choice(DIGITS)
    if random.random() < 0.5:
        g5 = random.choice(GRID_LETTERS_2).lower()
        g6 = random.choice(GRID_LETTERS_2).lower()
        return f"{g1}{g2}{g3}{g4}{g5}{g6}"
    return f"{g1}{g2}{g3}{g4}"


def random_rst():
    """Generate an RST signal report."""
    r = random.choice(["1", "2", "3", "4", "5"])
    s = random.choice(["1", "2", "3", "4", "5", "6", "7", "8", "9"])
    t = random.choice(["9", "8", "7"])
    if random.random() < 0.5:
        return f"{r}{s}{t}"
    return f"{r}{s}"


def random_db():
    """Generate a dB signal report for FT8."""
    return random.choice(
        [f"-{d:02d}" for d in range(1, 25)] + [f"+{d:02d}" for d in range(0, 15)]
    )


# --- RTTY generators (uppercase) ---


def gen_rtty():
    """Generate an RTTY-style message (uppercase)."""
    generators = [
        gen_rtty_cq,
        gen_rtty_qso_exchange,
        gen_rtty_contest,
        gen_rtty_wx_report,
        gen_rtty_beacon,
        gen_rtty_ragchew,
    ]
    return random.choice(generators)()


def gen_rtty_cq():
    call = random_callsign()
    repeats = random.randint(2, 4)
    cq = " ".join(["CQ"] * repeats)
    ending = random.choice(["K", "KN", "PSE K", ""])
    return f"{cq} DE {call} {call} {ending}".strip()


def gen_rtty_qso_exchange():
    my_call = random_callsign()
    their_call = random_callsign()
    rst = random_rst()
    name = random.choice(NAMES)
    city = random.choice(CITIES)
    parts = []
    parts.append(f"{their_call} DE {my_call}")
    parts.append(f"UR RST {rst} {rst}")
    if random.random() < 0.7:
        parts.append(f"NAME IS {name}")
    if random.random() < 0.6:
        parts.append(f"QTH IS {city}")
    if random.random() < 0.3:
        parts.append(f"RIG IS {random.choice(RIGS)}")
    parts.append(random.choice(["BTU", "KN", "K", "BK"]))
    return " ".join(parts)


def gen_rtty_contest():
    my_call = random_callsign()
    their_call = random_callsign()
    rst = random_rst()
    serial = random.randint(1, 9999)
    zone = random.randint(1, 40)
    templates = [
        f"{their_call} DE {my_call} 5NN {serial:04d} {serial:04d}",
        f"{their_call} {my_call} {rst} {zone:02d}",
        f"TU {their_call} DE {my_call} QRZ?",
        f"{their_call} {rst} {serial:04d} K",
    ]
    return random.choice(templates)


def gen_rtty_wx_report():
    call = random_callsign()
    temp = random.randint(-20, 110)
    wx = random.choice(WX_CONDITIONS)
    return f"WX HR IN {random.choice(CITIES)} IS {wx} TEMP {temp}F DE {call}"


def gen_rtty_beacon():
    call = random_callsign()
    grid = random_grid().upper()
    return f"VVV VVV VVV DE {call} {call} BEACON {grid} QSL VIA BUREAU"


def gen_rtty_ragchew():
    my_call = random_callsign()
    their_call = random_callsign()
    name = random.choice(NAMES)
    phrases = [
        f"TNX FER CALL {name}",
        f"FB {name} GLAD TO MEET U",
        f"HW CPY? AGN PSE",
        f"ANT IS {random.choice(ANTENNAS)} UP {random.randint(20,100)}FT",
        f"PWR IS {random.choice(['100', '500', '1000', '1500'])}W",
        f"BEEN LICENCED {random.randint(1,50)} YRS",
        f"73 ES HPE CUAGN",
        f"GL ES DX",
    ]
    msg = f"{their_call} DE {my_call} "
    msg += " ".join(random.sample(phrases, k=random.randint(2, 4)))
    msg += " " + random.choice(["K", "KN", "SK", "73"])
    return msg


# --- PSK31 generators (mixed case, conversational) ---


def gen_psk():
    """Generate a PSK31-style message (mixed case, conversational)."""
    generators = [
        gen_psk_cq,
        gen_psk_qso,
        gen_psk_ragchew,
        gen_psk_rig_info,
        gen_psk_wx,
        gen_psk_closing,
    ]
    return random.choice(generators)()


def gen_psk_cq():
    call = random_callsign()
    repeats = random.randint(2, 3)
    cq = " ".join(["CQ"] * repeats)
    name = random.choice(NAMES_MIXED)
    grid = random_grid()
    parts = [f"{cq} {cq} de {call} {call}"]
    if random.random() < 0.5:
        parts.append(f"{name} in {random.choice(CITIES).title()}")
    if random.random() < 0.4:
        parts.append(grid)
    parts.append(random.choice(["pse k", "k", "kn"]))
    return " ".join(parts)


def gen_psk_qso():
    my_call = random_callsign()
    their_call = random_callsign()
    rst = random_rst()
    name = random.choice(NAMES_MIXED)
    city = random.choice(CITIES).title()
    parts = [f"{their_call} de {my_call}"]
    parts.append(f"Hello {name}, thanks for the call.")
    parts.append(f"Your RST is {rst}.")
    parts.append(f"My name is {random.choice(NAMES_MIXED)} and QTH is {city}.")
    parts.append(random.choice(["btu", "back to you", "k", "kn"]))
    return " ".join(parts)


def gen_psk_ragchew():
    phrases = [
        f"Been a ham for {random.randint(1,50)} years now.",
        f"Running {random.choice(RIGS)} into a {random.choice(ANTENNAS).lower()}.",
        f"Band conditions are {random.choice(['good', 'fair', 'poor', 'excellent', 'marginal'])} today.",
        f"Working on {random.choice(BANDS)} band.",
        f"Just got back from {random.choice(CITIES).title()}.",
        f"Weather here is {random.choice(WX_CONDITIONS).lower()}, about {random.randint(20,95)}F.",
        f"Hoping to work some DX later.",
        f"Have you tried {random.choice(['FT8', 'JS8Call', 'Winlink', 'VARA', 'ARDOP'])}?",
        f"Nice signal here, solid copy.",
        f"Some QRM on freq but copy is ok.",
        f"I can hear you {random.choice(['loud and clear', 'fairly well', 'with some difficulty'])}.",
    ]
    return " ".join(random.sample(phrases, k=random.randint(2, 5)))


def gen_psk_rig_info():
    rig = random.choice(RIGS)
    ant = random.choice(ANTENNAS).lower()
    pwr = random.choice(["5", "10", "25", "50", "100", "200", "500", "1000", "1500"])
    parts = [f"My rig is a {rig} running {pwr}w"]
    parts.append(f"into a {ant}")
    if random.random() < 0.5:
        parts.append(f"at {random.randint(15,100)} feet")
    parts.append(f"on {random.choice(BANDS)}")
    return ". ".join(parts) + "."


def gen_psk_wx():
    city = random.choice(CITIES).title()
    temp = random.randint(-10, 105)
    wx = random.choice(WX_CONDITIONS).lower()
    return f"Weather in {city} is {wx}, temperature {temp}F. {random.choice(['Nice day for radio!', 'Good day to be on the air.', 'Perfect wx for antenna work.'])}"


def gen_psk_closing():
    name = random.choice(NAMES_MIXED)
    call = random_callsign()
    closings = [
        f"Well {name}, it was great chatting with you. 73 and hope to see you again! de {call} sk",
        f"Thanks for the nice QSO {name}. 73! de {call}",
        f"Must go now {name}, 73 es gd DX. de {call} sk sk",
        f"Very nice to meet you {name}. Best 73 de {call}",
        f"Ok {name}, thanks fer the QSO. Gl es 73 de {call} dit dit",
    ]
    return random.choice(closings)


# --- FT8 generators (structured, short) ---


def gen_ft8():
    """Generate an FT8-style message (structured, short format)."""
    generators = [
        gen_ft8_cq,
        gen_ft8_reply,
        gen_ft8_grid,
        gen_ft8_signal,
        gen_ft8_rrr,
        gen_ft8_73,
        gen_ft8_contest,
    ]
    return random.choice(generators)()


def gen_ft8_cq():
    call = random_callsign()
    grid = random_grid()[:4]
    if random.random() < 0.2:
        prefix = random.choice(["CQ DX", "CQ NA", "CQ EU", "CQ AS", "CQ SA", "CQ TEST", "CQ POTA"])
        return f"{prefix} {call} {grid}"
    return f"CQ {call} {grid}"


def gen_ft8_reply():
    call1 = random_callsign()
    call2 = random_callsign()
    grid = random_grid()[:4]
    if random.random() < 0.5:
        return f"{call1} {call2} {grid}"
    db = random_db()
    return f"{call1} {call2} {db}"


def gen_ft8_grid():
    call1 = random_callsign()
    call2 = random_callsign()
    grid = random_grid()[:4]
    return f"{call1} {call2} {grid}"


def gen_ft8_signal():
    call1 = random_callsign()
    call2 = random_callsign()
    db = random_db()
    return f"{call1} {call2} {db}"


def gen_ft8_rrr():
    call1 = random_callsign()
    call2 = random_callsign()
    msg = random.choice(["RRR", "RR73", "R" + random_db()])
    return f"{call1} {call2} {msg}"


def gen_ft8_73():
    call1 = random_callsign()
    call2 = random_callsign()
    return f"{call1} {call2} 73"


def gen_ft8_contest():
    call1 = random_callsign()
    call2 = random_callsign()
    rst = "5" + random.choice(["9", "8", "7"])
    state = random.choice([
        "AL","AK","AZ","AR","CA","CO","CT","DE","FL","GA","HI","ID","IL","IN",
        "IA","KS","KY","LA","ME","MD","MA","MI","MN","MS","MO","MT","NE","NV",
        "NH","NJ","NM","NY","NC","ND","OH","OK","OR","PA","RI","SC","SD","TN",
        "TX","UT","VT","VA","WA","WV","WI","WY","DC",
    ])
    return f"{call1} {call2} {rst} {state}"


# --- Rattlegram generators (freeform text) ---


def gen_rattlegram():
    """Generate Rattlegram-style messages (freeform readable text)."""
    generators = [
        gen_rattle_position,
        gen_rattle_message,
        gen_rattle_status,
        gen_rattle_chat,
        gen_rattle_emergency,
    ]
    return random.choice(generators)()


def gen_rattle_position():
    lat = round(random.uniform(-60, 70), 4)
    lon = round(random.uniform(-180, 180), 4)
    call = random_callsign()
    templates = [
        f"{call} position {lat} {lon}",
        f"Position report: {lat}N {abs(lon):.4f}W de {call}",
        f"GPS {lat},{lon} alt {random.randint(0,5000)}m {call}",
        f"Loc: {lat} {lon} grid {random_grid()} de {call}",
    ]
    return random.choice(templates)


def gen_rattle_message():
    call = random_callsign()
    messages = [
        f"Net check-in de {call} all ok",
        f"{call}: Arrived at destination safely",
        f"Message from {call}: Will be QRV on {random.choice(BANDS)} at {random.randint(1,12)}pm",
        f"{call} testing rattlegram {random.randint(1,100)}",
        f"de {call}: Equipment working fine. Standing by.",
        f"ARES net {call} checking in. No traffic.",
        f"{call}: Packet received ok. ACK.",
        f"Relay from {call}: Need supplies at base camp",
    ]
    return random.choice(messages)


def gen_rattle_status():
    call = random_callsign()
    statuses = [
        f"Battery {random.randint(20,100)}% Solar {random.choice(['good','fair','poor'])} de {call}",
        f"{call} status: operational. Temp {random.randint(-10,120)}F",
        f"Station {call} on air. PWR {random.choice(['5','10','25','50','100'])}W",
        f"Link quality: {random.randint(50,100)}% SNR {random.randint(-5,30)}dB de {call}",
    ]
    return random.choice(statuses)


def gen_rattle_chat():
    phrases = [
        "Hello, can you copy this?",
        "Testing 1 2 3. How copy?",
        "Good morning from the hilltop.",
        "Rain starting here. Moving inside.",
        "All stations, this is a test.",
        "Copy your last message. Standing by.",
        "Roger that. Will relay to base.",
        "Excellent copy on your signal.",
        f"QSO with {random_callsign()} was great.",
        f"Heard {random_callsign()} on {random.choice(BANDS)} just now.",
        "Everything looks good on this end.",
        "Switching to backup frequency now.",
    ]
    n = random.randint(1, 3)
    return " ".join(random.sample(phrases, k=n))


def gen_rattle_emergency():
    call = random_callsign()
    emergencies = [
        f"EMERGENCY de {call}: Need assistance at grid {random_grid()}",
        f"PRIORITY {call}: Medical situation. Request help.",
        f"WELFARE CHECK {call}: All members accounted for.",
        f"SKYWARN {call}: Severe weather spotted bearing {random.randint(0,359)} deg",
    ]
    return random.choice(emergencies)


# --- Garbage generators ---


def gen_garbage():
    """Generate garbage/noise text."""
    generators = [
        gen_garbage_random_ascii,
        gen_garbage_random_alpha,
        gen_garbage_punctuation,
        gen_garbage_repeated_chars,
        gen_garbage_corrupted,
        gen_garbage_random_spaced,
        gen_garbage_high_entropy,
        gen_garbage_numeric,
        gen_garbage_short_noise,
        gen_garbage_mixed_symbols,
    ]
    return random.choice(generators)()


def gen_garbage_random_ascii():
    length = random.randint(5, 200)
    chars = string.printable[:95]
    return "".join(random.choices(chars, k=length))


def gen_garbage_random_alpha():
    length = random.randint(5, 150)
    return "".join(random.choices(LETTERS + LETTERS.lower(), k=length))


def gen_garbage_punctuation():
    length = random.randint(10, 100)
    chars = string.punctuation + " "
    return "".join(random.choices(chars, k=length))


def gen_garbage_repeated_chars():
    char = random.choice(string.printable[:62])
    repeats = random.randint(10, 100)
    base = char * repeats
    # Insert a few random chars
    result = list(base)
    for _ in range(random.randint(0, 5)):
        pos = random.randint(0, len(result) - 1)
        result[pos] = random.choice(string.printable[:62])
    return "".join(result)


def gen_garbage_corrupted():
    """Generate near-miss corrupted ham text."""
    # Start with legit text and corrupt it
    legit = random.choice([gen_rtty, gen_psk, gen_ft8, gen_rattlegram])()
    result = list(legit)
    # Corrupt 40-70% of characters
    corruption = random.uniform(0.4, 0.7)
    n_corrupt = int(len(result) * corruption)
    positions = random.sample(range(len(result)), k=min(n_corrupt, len(result)))
    for pos in positions:
        result[pos] = random.choice(string.printable[:95])
    return "".join(result)


def gen_garbage_random_spaced():
    words = []
    for _ in range(random.randint(2, 15)):
        word_len = random.randint(1, 8)
        word = "".join(random.choices(LETTERS + LETTERS.lower(), k=word_len))
        words.append(word)
    return " ".join(words)


def gen_garbage_high_entropy():
    length = random.randint(20, 150)
    chars = string.printable[:95]
    return "".join(random.choices(chars, k=length))


def gen_garbage_numeric():
    length = random.randint(10, 80)
    return "".join(random.choices(DIGITS + " .-+", k=length))


def gen_garbage_short_noise():
    length = random.randint(1, 10)
    return "".join(random.choices(string.printable[:95], k=length))


def gen_garbage_mixed_symbols():
    length = random.randint(10, 100)
    chars = LETTERS + DIGITS + "!@#$%^&*()[]{}|\\/<>~`"
    return "".join(random.choices(chars, k=length))


# --- Main ---


def generate_dataset():
    random.seed(SEED)

    samples = []

    # RTTY: 12K
    for _ in range(12_000):
        samples.append((gen_rtty(), 1))

    # PSK31: 12K
    for _ in range(12_000):
        samples.append((gen_psk(), 1))

    # FT8: 16K
    for _ in range(16_000):
        samples.append((gen_ft8(), 1))

    # Rattlegram: 10K
    for _ in range(10_000):
        samples.append((gen_rattlegram(), 1))

    # Garbage: 50K
    for _ in range(TOTAL_GARBAGE):
        samples.append((gen_garbage(), 0))

    random.shuffle(samples)

    split = int(len(samples) * TRAIN_RATIO)
    train = samples[:split]
    test = samples[split:]

    os.makedirs("data", exist_ok=True)

    for filename, data in [("data/train.csv", train), ("data/test.csv", test)]:
        with open(filename, "w", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            writer.writerow(["text", "label"])
            for text, label in data:
                # Ensure no newlines in text
                clean = text.replace("\n", " ").replace("\r", " ")
                writer.writerow([clean, label])

    print(f"Generated {len(train)} training samples -> data/train.csv")
    print(f"Generated {len(test)} test samples -> data/test.csv")
    print(f"Label distribution (train): {sum(1 for _,l in train if l==1)} legit, {sum(1 for _,l in train if l==0)} garbage")
    print(f"Label distribution (test):  {sum(1 for _,l in test if l==1)} legit, {sum(1 for _,l in test if l==0)} garbage")


if __name__ == "__main__":
    generate_dataset()
