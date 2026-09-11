#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Генератор синтетической витрины интернет-магазина для SQL-исследования.

ЗАЧЕМ СИНТЕТИКА.
Открытые датасеты (Chinook, UCI Online Retail, Olist) не содержат
одновременно себестоимости и лога событий, поэтому два из обязательных
вопросов — маржа по категориям и воронка — на них не считаются честно.
Здесь данные генерируются скриптом с зафиксированным seed: витрина
воспроизводима до строки, а заложенные закономерности известны заранее,
что позволяет проверить корректность аналитических запросов.

ЧТО НАМЕРЕННО ЗАЛОЖЕНО В ДАННЫЕ (эти эффекты SQL-запросы должны найти):
  1. Сезонность: пик ноябрь-декабрь (x1.70 / x1.45), провал январь-февраль,
     плюс органический рост ~1.5% в месяц.
  2. Когорты: клиенты, привлечённые в ноябре-декабре на скидках, удерживаются
     примерно вдвое хуже — большая когорта не равно хорошая когорта.
  3. Маржа: Apparel имеет высокую валовую маржу, но 27% возвратов;
     Electronics — большая выручка при валовой марже ~15%.
     Рейтинг категорий по валовой и по чистой марже РАЗНЫЙ.
  4. Инфляция закупки: себестоимость растёт быстрее цены продажи
     => маржинальность сжимается на горизонте 32 месяцев.
  5. Воронка: мобильный трафик даёт больше сессий, но заметно хуже проходит
     шаг checkout -> purchase; paid_social льёт объём с плохим качеством.
  6. LTV/CAC: CAC в paid_social растёт ~2.8% в месяц, удержание там худшее
     => канал не окупается; referral/email — наоборот.
  7. Парето: примерно 20% товаров дают около 80% выручки (zipf-популярность).

ЗАПУСК:  python3 data/generate_ecommerce_db.py
Только стандартная библиотека. Пересборка занимает менее минуты.
"""

import math
import os
import random
import sqlite3
from datetime import date, datetime, timedelta

SEED = 20260911
HERE = os.path.dirname(os.path.abspath(__file__))
SCHEMA_PATH = os.path.join(HERE, "schema.sql")
DB_PATH = os.path.join(HERE, "ecommerce.db")

DATA_START = date(2024, 1, 1)
DATA_END = date(2026, 8, 31)
N_CUSTOMERS = 10_000
TARGET_SESSIONS = 350_000

# --------------------------------------------------------------------------
# Параметры «физики мира»
# --------------------------------------------------------------------------

# Сезонность спроса (множитель к вероятности покупки в данном месяце)
ORD_SEASON = {1: 0.78, 2: 0.75, 3: 0.90, 4: 0.95, 5: 1.00, 6: 0.92,
              7: 0.90, 8: 0.88, 9: 1.02, 10: 1.15, 11: 1.70, 12: 1.45}

# Сезонность привлечения: в ноябре скидочный наплыв новых клиентов
ACQ_SEASON = {1: 0.85, 2: 0.80, 3: 0.95, 4: 1.00, 5: 1.00, 6: 0.90,
              7: 0.85, 8: 0.90, 9: 1.05, 10: 1.20, 11: 2.10, 12: 1.30}

MONTHLY_GROWTH = 1.015           # органический рост бизнеса
DOW_WEIGHTS = [1.06, 1.04, 1.02, 1.03, 1.05, 0.90, 0.90]   # Пн..Вс
HOUR_WEIGHTS = [0.3, 0.2, 0.15, 0.1, 0.1, 0.2, 0.5, 1.0, 1.6, 2.0, 2.2, 2.3,
                2.6, 2.5, 2.2, 2.0, 2.1, 2.4, 2.8, 3.0, 2.9, 2.4, 1.5, 0.7]

# Каналы привлечения: доля в привлечении, качество удержания,
# базовый CAC и его помесячная инфляция.
#
# CAC откалиброван относительно экономики заказа: средний чек ~550,
# вклад с первого заказа ~130. Платные каналы стоят 120-150 и дорожают,
# поэтому окупаются НЕ с первого заказа — как и в реальном e-commerce.
# У paid_social инфляция CAC максимальная (2.8%/мес): канал и дорожает,
# и удерживает хуже всех -> к концу периода перестаёт окупаться.
CHANNELS = {
    "paid_search":    {"share": 0.20, "retention": 0.92, "cac": 145.0, "cac_infl": 0.012},
    "paid_social":    {"share": 0.24, "retention": 0.58, "cac": 120.0, "cac_infl": 0.028},
    "organic_search": {"share": 0.18, "retention": 1.28, "cac": 8.0,   "cac_infl": 0.004},
    "email":          {"share": 0.10, "retention": 1.18, "cac": 12.0,  "cac_infl": 0.003},
    "referral":       {"share": 0.09, "retention": 1.34, "cac": 35.0,  "cac_infl": 0.005},
    "direct":         {"share": 0.13, "retention": 1.12, "cac": 0.0,   "cac_infl": 0.0},
    "affiliate":      {"share": 0.06, "retention": 0.86, "cac": 85.0,  "cac_infl": 0.014},
}

# Дерево категорий + экономика каждой ветки
# cost_ratio  — доля себестоимости в цене (чем выше, тем тоньше маржа)
# return_rate — доля позиций, которые вернут (главный «убийца» маржи в Apparel)
# cost_infl   — помесячная инфляция закупки; сравнивать с PRICE_INFL ниже:
#               закупка дорожает быстрее цены => маржа медленно сжимается
# popularity  — множитель спроса относительно других веток
CATEGORY_TREE = {
    "Electronics": {
        "children": ["Smartphones", "Laptops", "Audio", "Wearables"],
        "cost_ratio": (0.70, 0.82), "price": (120, 1800),
        "return_rate": 0.06, "cost_infl": 0.0042, "popularity": 0.80,
    },
    "Home & Kitchen": {
        "children": ["Cookware", "Furniture", "Home Decor"],
        "cost_ratio": (0.52, 0.66), "price": (25, 650),
        "return_rate": 0.09, "cost_infl": 0.0032, "popularity": 1.05,
    },
    "Apparel": {
        "children": ["Men's Clothing", "Women's Clothing", "Footwear"],
        "cost_ratio": (0.32, 0.46), "price": (18, 190),
        "return_rate": 0.27, "cost_infl": 0.0028, "popularity": 2.40,
    },
    "Beauty": {
        "children": ["Skincare", "Makeup", "Fragrance"],
        "cost_ratio": (0.26, 0.42), "price": (8, 130),
        "return_rate": 0.05, "cost_infl": 0.0022, "popularity": 1.90,
    },
    "Sports & Outdoors": {
        "children": ["Fitness Equipment", "Outdoor Gear", "Cycling"],
        "cost_ratio": (0.50, 0.64), "price": (28, 720),
        "return_rate": 0.12, "cost_infl": 0.0035, "popularity": 0.95,
    },
}

PRICE_INFL = 0.0030      # помесячный рост отпускной цены

COUNTRIES = [
    ("US", "North America", ["New York", "Chicago", "Austin", "Seattle", "Denver"], 0.28),
    ("UK", "Western Europe", ["London", "Manchester", "Bristol", "Leeds"], 0.16),
    ("DE", "Central Europe", ["Berlin", "Munich", "Hamburg", "Cologne"], 0.14),
    ("FR", "Western Europe", ["Paris", "Lyon", "Marseille", "Toulouse"], 0.10),
    ("NL", "Western Europe", ["Amsterdam", "Rotterdam", "Utrecht"], 0.07),
    ("ES", "Southern Europe", ["Madrid", "Barcelona", "Valencia"], 0.07),
    ("IT", "Southern Europe", ["Milan", "Rome", "Turin"], 0.06),
    ("PL", "Central Europe", ["Warsaw", "Krakow", "Wroclaw"], 0.05),
    ("SE", "Northern Europe", ["Stockholm", "Gothenburg"], 0.04),
    ("CA", "North America", ["Toronto", "Vancouver", "Montreal"], 0.03),
]

DEVICES_SESSION = (["mobile", "desktop", "tablet"], [0.60, 0.32, 0.08])
DEVICES_ORDER = (["mobile", "desktop", "tablet"], [0.46, 0.46, 0.08])

# Вероятности прохождения шагов воронки (базовые), домножаются на модификаторы
FUNNEL_BASE = {"view": 0.72, "cart": 0.31, "checkout": 0.56, "purchase": 0.62}
# Склонность дойти до оформления и БРОСИТЬ его (модификатор шага
# add_to_cart -> checkout_start у неконвертирующих сессий). Значение > 1
# у мобильных = больше начатых и незавершённых оформлений, т.е. заметная
# «протечка» именно на последнем шаге — её и должен найти запрос 03.
DEVICE_CHECKOUT_ABANDON = {
    "mobile": 1.15, "desktop": 0.90, "tablet": 1.00,
}
SOURCE_FUNNEL_MOD = {           # модификатор на шаг view -> cart (качество трафика)
    "paid_social": 0.62, "paid_search": 0.98, "organic_search": 1.24,
    "email": 1.30, "referral": 1.18, "direct": 1.14, "affiliate": 0.80,
}

RETURN_REASONS = ["size_mismatch", "damaged", "not_as_described",
                 "changed_mind", "late_delivery"]
PAY_METHODS = (["card", "paypal", "apple_pay", "bank_transfer", "gift_card"],
               [0.56, 0.20, 0.15, 0.06, 0.03])

BRANDS = ["Aurora", "Northwind", "Vertex", "Lumen", "Cobalt", "Harbor", "Pike",
          "Solace", "Ridgeline", "Meridian", "Kestrel", "Alder", "Foxglove",
          "Tessera", "Juniper", "Onyx", "Verdant", "Halcyon"]
MODELS = ["Classic", "Pro", "Lite", "Max", "Essential", "Studio", "Trail",
          "Everyday", "Signature", "Compact", "Ultra", "Core", "Prime"]

rnd = random.Random(SEED)
HOURS24 = list(range(24))


def cumw(weights):
    """Кумулятивные веса.

    random.choices(weights=...) на КАЖДОМ вызове заново накапливает весь
    список весов — при 500 товарах и ~700k выборок это сотни миллионов
    операций. С cum_weights выбор идёт бинарным поиском за O(log n).
    """
    out, acc = [], 0.0
    for w in weights:
        acc += w
        out.append(acc)
    return out


HOUR_CUM = cumw(HOUR_WEIGHTS)
_DAY_CACHE = {}


# --------------------------------------------------------------------------
# Утилиты
# --------------------------------------------------------------------------

def month_list(start, end):
    """Список (year, month) от start до end включительно."""
    out, y, m = [], start.year, start.month
    while (y, m) <= (end.year, end.month):
        out.append((y, m))
        m += 1
        if m == 13:
            y, m = y + 1, 1
    return out


MONTHS = month_list(DATA_START, DATA_END)
MONTH_INDEX = {ym: i for i, ym in enumerate(MONTHS)}


def days_in_month(y, m):
    return ((date(y + 1, 1, 1) if m == 12 else date(y, m + 1, 1)) - date(y, m, 1)).days


def random_ts_in_month(y, m):
    """Случайный момент внутри месяца с учётом дня недели и часа суток."""
    cached = _DAY_CACHE.get((y, m))
    if cached is None:
        days = list(range(1, days_in_month(y, m) + 1))
        cached = (days, cumw([DOW_WEIGHTS[date(y, m, d).weekday()] for d in days]))
        _DAY_CACHE[(y, m)] = cached
    days, day_cum = cached
    d = rnd.choices(days, cum_weights=day_cum)[0]
    h = rnd.choices(HOURS24, cum_weights=HOUR_CUM)[0]
    return datetime(y, m, d, h, rnd.randrange(60), rnd.randrange(60))


def fmt(dt):
    return dt.strftime("%Y-%m-%d %H:%M:%S")


def clamp(x, lo, hi):
    return max(lo, min(hi, x))


def promo_code_for(dt):
    """Промокоды привязаны к распродажам; вне их окон промо редкие."""
    m, y = dt.month, dt.year % 100
    if m == 11:
        return "BLACKFRIDAY%d" % y
    if m == 12:
        return "XMAS%d" % y
    if m == 7:
        return "SUMMER%d" % y
    if m == 1:
        return "NEWYEAR%d" % y
    return rnd.choice([None, None, None, None, "WELCOME10", "FREESHIP"])


# --------------------------------------------------------------------------
# Генерация справочников
# --------------------------------------------------------------------------

def build_categories():
    """Возвращает (rows, leaf_meta) — плоский список категорий и мета листьев."""
    rows, leaf_meta = [], {}
    cid = 0
    for top, cfg in CATEGORY_TREE.items():
        cid += 1
        top_id = cid
        rows.append((top_id, top, None, 1))
        for child in cfg["children"]:
            cid += 1
            rows.append((cid, child, top_id, 2))
            leaf_meta[cid] = {"top": top, "cfg": cfg, "name": child}
    return rows, leaf_meta


def build_suppliers(n=25):
    rows = []
    countries = ["CN", "DE", "PL", "US", "VN", "TR", "IT", "PT"]
    for i in range(1, n + 1):
        rows.append((i,
                     "%s %s" % (rnd.choice(BRANDS), rnd.choice(["Trading", "Industries", "Supply Co", "Group"])),
                     rnd.choice(countries),
                     rnd.randrange(7, 61),
                     round(rnd.uniform(2.6, 4.9), 2)))
    return rows


def build_products(leaf_meta, n_suppliers):
    """~35 товаров на лист. Популярность внутри листа — zipf (для Парето)."""
    rows, meta = [], {}
    pid = 0
    for leaf_id, info in leaf_meta.items():
        cfg = info["cfg"]
        lo, hi = cfg["price"]
        n = rnd.randrange(30, 41)
        weights = [1.0 / ((i + 1) ** 0.85) for i in range(n)]
        rnd.shuffle(weights)
        for i in range(n):
            pid += 1
            # Логнормальная цена внутри диапазона категории: дешёвых товаров больше
            u = rnd.random() ** 1.7
            price = round(lo + (hi - lo) * u, 2)
            price = max(price, 4.99)
            cr = rnd.uniform(*cfg["cost_ratio"])
            cost = round(price * cr, 2)
            launch = DATA_START - timedelta(days=rnd.randrange(0, 400))
            if rnd.random() < 0.18:            # часть ассортимента вводится по ходу
                launch = DATA_START + timedelta(days=rnd.randrange(0, 700))
            rows.append((pid,
                         "SKU-%05d" % pid,
                         "%s %s %s" % (rnd.choice(BRANDS), info["name"].split()[0], rnd.choice(MODELS)),
                         leaf_id,
                         rnd.randrange(1, n_suppliers + 1),
                         price, cost,
                         launch.isoformat(),
                         1 if rnd.random() > 0.07 else 0))
            meta[pid] = {"leaf": leaf_id, "top": info["top"], "cfg": cfg,
                         "price": price, "cost": cost, "launch": launch,
                         "weight": weights[i] * cfg["popularity"]}
    return rows, meta


def build_customers():
    """Распределяем регистрации по месяцам с сезонностью и ростом."""
    ch_names = list(CHANNELS.keys())
    ch_shares = [CHANNELS[c]["share"] for c in ch_names]
    c_names = [c[0] for c in COUNTRIES]
    c_shares = [c[3] for c in COUNTRIES]
    country_by_code = {c[0]: c for c in COUNTRIES}

    m_weights = [ACQ_SEASON[m] * (MONTHLY_GROWTH ** i) for i, (y, m) in enumerate(MONTHS)]
    total_w = sum(m_weights)
    per_month = [max(1, int(round(N_CUSTOMERS * w / total_w))) for w in m_weights]

    rows, meta = [], {}
    cust_id = 0
    for (y, m), cnt in zip(MONTHS, per_month):
        promo_cohort = m in (11, 12)          # скидочный наплыв
        for _ in range(cnt):
            cust_id += 1
            ts = random_ts_in_month(y, m)
            code = rnd.choices(c_names, weights=c_shares)[0]
            _, region, cities, _ = country_by_code[code]
            channel = rnd.choices(ch_names, weights=ch_shares)[0]
            device = rnd.choices(*DEVICES_SESSION)[0]

            # Латентная лояльность: логнормальная, домножается на качество канала
            base = clamp(rnd.lognormvariate(-2.15, 0.72), 0.01, 0.62)
            loyalty = base * CHANNELS[channel]["retention"]
            if promo_cohort:
                loyalty *= 0.52               # скидочные когорты удерживаются хуже
            decay = rnd.uniform(0.055, 0.185)

            rows.append((cust_id, "CUST-%06d" % cust_id, fmt(ts), code, region,
                         rnd.choice(cities), channel, device,
                         1 if rnd.random() < 0.06 else 0))
            meta[cust_id] = {
                "signup": ts, "channel": channel, "device": device,
                "country": code, "loyalty": clamp(loyalty, 0.005, 0.75),
                "decay": decay,
                "fav_top": rnd.choice(list(CATEGORY_TREE.keys())),
                "promo_cohort": promo_cohort,
            }
    return rows, meta


# --------------------------------------------------------------------------
# Генерация заказов
# --------------------------------------------------------------------------

def build_orders(cust_meta, prod_meta):
    """Первый заказ = момент регистрации. Далее — помесячный затухающий хазард."""
    orders, items, payments, returns_ = [], [], [], []
    order_id = item_id = pay_id = ret_id = 0

    # Товары, сгруппированные по корневой категории — для выбора «любимой» ветки
    by_top = {}
    for pid, pm in prod_meta.items():
        by_top.setdefault(pm["top"], []).append(pid)
    all_pids = list(prod_meta.keys())
    all_cum = cumw([prod_meta[p]["weight"] for p in all_pids])
    top_pids = {t: pids for t, pids in by_top.items()}
    top_cum = {t: cumw([prod_meta[p]["weight"] for p in pids]) for t, pids in by_top.items()}

    for cid, cm in cust_meta.items():
        signup = cm["signup"]
        start_idx = MONTH_INDEX[(signup.year, signup.month)]

        # Даты всех заказов клиента: первый в момент регистрации
        order_dates = [signup]
        for k in range(1, len(MONTHS) - start_idx):
            y, m = MONTHS[start_idx + k]
            p = cm["loyalty"] * math.exp(-cm["decay"] * k) * ORD_SEASON[m]
            p = clamp(p, 0.0, 0.85)
            if rnd.random() < p:
                order_dates.append(random_ts_in_month(y, m))
                if rnd.random() < 0.12:                    # изредка два заказа в месяц
                    order_dates.append(random_ts_in_month(y, m))

        for od in order_dates:
            order_id += 1
            midx = MONTH_INDEX[(od.year, od.month)]
            age_days = (DATA_END - od.date()).days

            # Статус: свежие заказы ещё в пути, ~3.5% отменяются
            r = rnd.random()
            if r < 0.035:
                status = "cancelled"
            elif age_days < 3:
                status = "processing"
            elif age_days < 9:
                status = "shipped"
            else:
                status = "delivered"
            delivered = fmt(od + timedelta(days=rnd.randrange(2, 12),
                                           hours=rnd.randrange(0, 24))) if status == "delivered" else None

            device = rnd.choices(*DEVICES_ORDER)[0]
            # Повторные заказы чаще приходят из direct/email, а не из платного
            channel = cm["channel"] if od == signup else rnd.choices(
                ["direct", "email", "organic_search", cm["channel"]],
                weights=[0.38, 0.22, 0.20, 0.20])[0]
            promo = promo_code_for(od)

            # --- позиции заказа ---
            n_items = rnd.choices([1, 2, 3, 4, 5], weights=[0.44, 0.27, 0.16, 0.08, 0.05])[0]
            chosen, subtotal = [], 0.0
            for _ in range(n_items):
                if rnd.random() < 0.55:
                    pool, cw = top_pids[cm["fav_top"]], top_cum[cm["fav_top"]]
                else:
                    pool, cw = all_pids, all_cum
                pid = rnd.choices(pool, cum_weights=cw)[0]
                pm = prod_meta[pid]
                if pm["launch"] > od.date():            # товар ещё не запущен
                    continue
                qty = rnd.choices([1, 2, 3], weights=[0.80, 0.15, 0.05])[0]
                if pm["price"] < 40:
                    qty = rnd.choices([1, 2, 3, 4], weights=[0.55, 0.25, 0.13, 0.07])[0]

                # Цена растёт медленнее себестоимости => маржа сжимается
                price = round(pm["price"] * (1 + PRICE_INFL * midx) * rnd.uniform(0.97, 1.03), 2)
                cost = round(pm["cost"] * (1 + pm["cfg"]["cost_infl"] * midx) * rnd.uniform(0.98, 1.02), 2)

                # Скидки глубже в промо-месяцы
                if od.month in (11, 12, 7):
                    disc = rnd.choices([0.0, 0.10, 0.15, 0.20, 0.30, 0.40],
                                       weights=[0.15, 0.20, 0.22, 0.22, 0.14, 0.07])[0]
                else:
                    disc = rnd.choices([0.0, 0.05, 0.10, 0.15, 0.25],
                                       weights=[0.58, 0.16, 0.14, 0.08, 0.04])[0]

                item_id += 1
                items.append((item_id, order_id, pid, qty, price, cost, disc))
                chosen.append((item_id, pid, qty, price, disc, pm))
                subtotal += qty * price * (1 - disc)

            if not chosen:                    # все товары оказались не запущены
                order_id -= 1
                continue

            ship = 0.0 if subtotal > 75 else round(rnd.uniform(4.99, 9.99), 2)
            orders.append((order_id, "ORD-%07d" % order_id, cid, fmt(od), status,
                           channel, device, cm["country"], ship, promo, delivered))

            # --- оплата ---
            pay_id += 1
            pay_status = "failed" if status == "cancelled" and rnd.random() < 0.45 else "captured"
            payments.append((pay_id, order_id, rnd.choices(*PAY_METHODS)[0],
                             round(subtotal + ship, 2),
                             fmt(od + timedelta(minutes=rnd.randrange(0, 25))), pay_status))

            # --- возвраты (только по доставленным заказам) ---
            if status == "delivered":
                for (iid, pid, qty, price, disc, pm) in chosen:
                    rate = pm["cfg"]["return_rate"]
                    if disc >= 0.30:
                        rate *= 1.25          # глубокая скидка -> больше возвратов
                    if rnd.random() < rate:
                        ret_id += 1
                        qret = qty if qty == 1 or rnd.random() < 0.7 else rnd.randrange(1, qty)
                        refund = round(qret * price * (1 - disc), 2)
                        rts = od + timedelta(days=rnd.randrange(5, 35))
                        if rts.date() > DATA_END:
                            continue
                        returns_.append((ret_id, iid, fmt(rts), qret, refund,
                                         rnd.choices(RETURN_REASONS,
                                                     weights=[0.34, 0.14, 0.16, 0.28, 0.08])[0]))
    return orders, items, payments, returns_


# --------------------------------------------------------------------------
# Генерация сессий и событий (воронка)
# --------------------------------------------------------------------------

def build_sessions_events(orders, cust_meta, prod_meta, items_by_order):
    """
    Конвертирующая сессия создаётся под каждый НЕотменённый заказ,
    поэтому события purchase и таблица orders сходятся один-в-один.
    Остальные сессии — неконвертирующие, обрываются на одном из шагов.

    ЗАМЕЧАНИЕ О МОДЕЛИ: в лог попадают только вовлечённые сессии
    (отказы/боты исключены на стороне трекера). Поэтому итоговая
    конверсия сессия->заказ выше типичной для e-commerce 2-3%.
    """
    sessions, events = [], []
    sid = eid = 0
    all_pids = list(prod_meta.keys())
    all_cum = cumw([prod_meta[p]["weight"] for p in all_pids])

    # 1) Конвертирующие сессии
    for o in orders:
        (order_id, _uid, cid, ots, status, channel, device, country, _sc, _pc, _dts) = o
        if status == "cancelled":
            continue
        sid += 1
        od = datetime.strptime(ots, "%Y-%m-%d %H:%M:%S")
        start = od - timedelta(minutes=rnd.randrange(4, 46))
        sessions.append((sid, "SESS-%08d" % sid, cid, fmt(start), device, channel,
                         country, rnd.choice(["/", "/category", "/search", "/product", "/promo"])))
        t = start
        prods = [it[2] for it in items_by_order.get(order_id, [])]
        if not prods:
            prods = [rnd.choices(all_pids, cum_weights=all_cum)[0]]
        for pid in prods[:3]:
            t += timedelta(seconds=rnd.randrange(20, 200))
            eid += 1
            events.append((eid, sid, fmt(t), "product_view", pid, None))
        for pid in prods[:2]:
            t += timedelta(seconds=rnd.randrange(15, 120))
            eid += 1
            events.append((eid, sid, fmt(t), "add_to_cart", pid, None))
        t += timedelta(seconds=rnd.randrange(30, 300))
        eid += 1
        events.append((eid, sid, fmt(t), "checkout_start", None, None))
        eid += 1
        events.append((eid, sid, fmt(od), "purchase", None, order_id))

    # 2) Неконвертирующие сессии
    n_extra = max(0, TARGET_SESSIONS - sid)
    span_days = (DATA_END - DATA_START).days
    cust_ids = list(cust_meta.keys())
    src_names = list(SOURCE_FUNNEL_MOD.keys())
    src_w = [CHANNELS[s]["share"] for s in src_names]
    country_codes = [c[0] for c in COUNTRIES]
    country_shares = [c[3] for c in COUNTRIES]
    month_cum = cumw([ORD_SEASON[m] * (MONTHLY_GROWTH ** i)
                      for i, (y, m) in enumerate(MONTHS)])

    for _ in range(n_extra):
        sid += 1
        # Дата сессии подчиняется той же сезонности, что и спрос
        y, m = rnd.choices(MONTHS, cum_weights=month_cum)[0]
        start = random_ts_in_month(y, m)
        device = rnd.choices(*DEVICES_SESSION)[0]
        source = rnd.choices(src_names, weights=src_w)[0]
        # ~35% сессий залогинены (известный клиент), остальные анонимные
        cust = None
        if rnd.random() < 0.35:
            c = rnd.choice(cust_ids)
            if cust_meta[c]["signup"] <= start:
                cust = c
        country = (cust_meta[cust]["country"] if cust
                   else rnd.choices(country_codes, weights=country_shares)[0])
        sessions.append((sid, "SESS-%08d" % sid, cust, fmt(start), device, source,
                         country, rnd.choice(["/", "/category", "/search", "/product", "/promo"])))

        t = start
        # Шаг 1: просмотр товара
        if rnd.random() >= FUNNEL_BASE["view"] * SOURCE_FUNNEL_MOD[source] * 0.92:
            continue
        n_views = rnd.choices([1, 2, 3, 4], weights=[0.50, 0.27, 0.15, 0.08])[0]
        for _ in range(n_views):
            t += timedelta(seconds=rnd.randrange(20, 240))
            eid += 1
            events.append((eid, sid, fmt(t), "product_view",
                           rnd.choices(all_pids, cum_weights=all_cum)[0], None))
        # Шаг 2: добавление в корзину
        if rnd.random() >= FUNNEL_BASE["cart"] * SOURCE_FUNNEL_MOD[source]:
            continue
        t += timedelta(seconds=rnd.randrange(15, 180))
        eid += 1
        events.append((eid, sid, fmt(t), "add_to_cart",
                       rnd.choices(all_pids, cum_weights=all_cum)[0], None))
        # Шаг 3: начало оформления (мобильные чаще доходят сюда и бросают)
        if rnd.random() >= FUNNEL_BASE["checkout"] * DEVICE_CHECKOUT_ABANDON[device]:
            continue
        t += timedelta(seconds=rnd.randrange(30, 400))
        eid += 1
        events.append((eid, sid, fmt(t), "checkout_start", None, None))
        # Шаг 4 (purchase) для этих сессий не наступает — заказ бы уже существовал

    return sessions, events


def build_marketing_spend(cust_rows):
    """Расход = число привлечённых * CAC канала на этот месяц * шум."""
    acq = {}
    for r in cust_rows:
        ch, ts = r[6], r[2]
        key = (ch, ts[:7])
        acq[key] = acq.get(key, 0) + 1
    rows, i = [], 0
    for ch, cfg in CHANNELS.items():
        for idx, (y, m) in enumerate(MONTHS):
            mk = "%04d-%02d" % (y, m)
            n = acq.get((ch, mk), 0)
            cac = cfg["cac"] * (1 + cfg["cac_infl"] * idx)
            spend = round(n * cac * rnd.uniform(0.88, 1.14), 2)
            if cfg["cac"] == 0:
                spend = 0.0
            clicks = int(n * rnd.uniform(18, 46)) if spend > 0 else int(n * rnd.uniform(6, 14))
            i += 1
            rows.append((i, ch, mk, spend, clicks * rnd.randrange(9, 26), clicks))
    return rows


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def main():
    if os.path.exists(DB_PATH):
        os.remove(DB_PATH)
    con = sqlite3.connect(DB_PATH)
    con.executescript(open(SCHEMA_PATH, encoding="utf-8").read())

    print("categories/suppliers/products ...")
    cats, leaf_meta = build_categories()
    sups = build_suppliers()
    prods, prod_meta = build_products(leaf_meta, len(sups))

    print("customers ...")
    cust_rows, cust_meta = build_customers()

    print("orders / items / payments / returns ...")
    orders, items, payments, returns_ = build_orders(cust_meta, prod_meta)

    items_by_order = {}
    for it in items:
        items_by_order.setdefault(it[1], []).append(it)

    print("sessions / events ...")
    sessions, events = build_sessions_events(orders, cust_meta, prod_meta, items_by_order)

    print("marketing spend ...")
    spend = build_marketing_spend(cust_rows)

    con.executemany("INSERT INTO categories VALUES (?,?,?,?)", cats)
    con.executemany("INSERT INTO suppliers  VALUES (?,?,?,?,?)", sups)
    con.executemany("INSERT INTO products   VALUES (?,?,?,?,?,?,?,?,?)", prods)
    con.executemany("INSERT INTO customers  VALUES (?,?,?,?,?,?,?,?,?)", cust_rows)
    con.executemany("INSERT INTO orders     VALUES (?,?,?,?,?,?,?,?,?,?,?)", orders)
    con.executemany("INSERT INTO order_items VALUES (?,?,?,?,?,?,?)", items)
    con.executemany("INSERT INTO payments   VALUES (?,?,?,?,?,?)", payments)
    con.executemany("INSERT INTO order_returns VALUES (?,?,?,?,?,?)", returns_)
    con.executemany("INSERT INTO sessions   VALUES (?,?,?,?,?,?,?,?)", sessions)
    con.executemany("INSERT INTO events     VALUES (?,?,?,?,?,?)", events)
    con.executemany("INSERT INTO marketing_spend VALUES (?,?,?,?,?,?)", spend)
    con.commit()
    con.execute("ANALYZE")
    con.commit()

    print("\n--- ИТОГО ---")
    for t in ["categories", "suppliers", "products", "customers", "orders",
              "order_items", "payments", "order_returns", "sessions",
              "events", "marketing_spend"]:
        n = con.execute("SELECT COUNT(*) FROM %s" % t).fetchone()[0]
        print("%-18s %9d" % (t, n))
    print("период: %s .. %s" % con.execute(
        "SELECT MIN(order_ts), MAX(order_ts) FROM orders").fetchone())
    print("файл:   %.1f MB" % (os.path.getsize(DB_PATH) / 1e6))
    con.close()


if __name__ == "__main__":
    main()
