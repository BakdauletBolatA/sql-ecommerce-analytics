-- =====================================================================
--  E-COMMERCE ANALYTICS WAREHOUSE — DDL
--  Диалект: SQLite 3.43+ (CTE, оконные функции, generated columns)
--
--  Модель: нормализованная OLTP-схема интернет-магазина.
--  11 связанных таблиц, три смысловых слоя:
--    1) Справочники : categories, suppliers, products, customers
--    2) Транзакции  : orders, order_items, payments, order_returns
--    3) Поведение   : sessions, events, marketing_spend
--
--  Ключевые связи (FK):
--    categories.parent_category_id -> categories.category_id  (иерархия, 2 уровня)
--    products.category_id          -> categories.category_id
--    products.supplier_id          -> suppliers.supplier_id
--    orders.customer_id            -> customers.customer_id
--    order_items.order_id          -> orders.order_id
--    order_items.product_id        -> products.product_id
--    payments.order_id             -> orders.order_id
--    order_returns.order_item_id   -> order_items.order_item_id
--    sessions.customer_id          -> customers.customer_id   (NULL = аноним)
--    events.session_id             -> sessions.session_id
--    events.order_id               -> orders.order_id         (только для purchase)
-- =====================================================================

PRAGMA foreign_keys = ON;

DROP TABLE IF EXISTS events;
DROP TABLE IF EXISTS sessions;
DROP TABLE IF EXISTS order_returns;
DROP TABLE IF EXISTS payments;
DROP TABLE IF EXISTS order_items;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS products;
DROP TABLE IF EXISTS suppliers;
DROP TABLE IF EXISTS categories;
DROP TABLE IF EXISTS customers;
DROP TABLE IF EXISTS marketing_spend;

-- ---------------------------------------------------------------------
-- 1. СПРАВОЧНИКИ
-- ---------------------------------------------------------------------

-- Иерархия категорий: 5 корневых -> 15 листовых.
-- parent_category_id ссылается на эту же таблицу => рекурсивный CTE
-- в 02_category_margin.sql поднимает лист до корня.
CREATE TABLE categories (
    category_id         INTEGER PRIMARY KEY,
    category_name       TEXT    NOT NULL,
    parent_category_id  INTEGER REFERENCES categories(category_id),
    category_level      INTEGER NOT NULL          -- 1 = корень, 2 = лист
);

CREATE TABLE suppliers (
    supplier_id     INTEGER PRIMARY KEY,
    supplier_name   TEXT    NOT NULL,
    country         TEXT    NOT NULL,
    lead_time_days  INTEGER NOT NULL,             -- срок поставки
    quality_rating  REAL    NOT NULL              -- 1.0 .. 5.0
);

-- unit_cost — плановая закупочная цена. В order_items лежит СНИМОК
-- себестоимости на момент заказа (цены поставщиков дрейфуют во времени),
-- поэтому историческую маржу считаем по order_items.unit_cost,
-- а не по products.unit_cost.
CREATE TABLE products (
    product_id   INTEGER PRIMARY KEY,
    sku          TEXT    NOT NULL UNIQUE,
    product_name TEXT    NOT NULL,
    category_id  INTEGER NOT NULL REFERENCES categories(category_id),
    supplier_id  INTEGER NOT NULL REFERENCES suppliers(supplier_id),
    list_price   REAL    NOT NULL CHECK (list_price > 0),
    unit_cost    REAL    NOT NULL CHECK (unit_cost  > 0),
    launch_date  TEXT    NOT NULL,                -- 'YYYY-MM-DD'
    is_active    INTEGER NOT NULL DEFAULT 1
);

-- acquisition_channel — канал ПЕРВОГО привлечения (фиксируется навсегда).
-- Именно он используется в LTV/CAC-анализе (06), т.к. атрибуция когорты
-- должна быть неизменной, иначе LTV «перетекает» между каналами.
CREATE TABLE customers (
    customer_id         INTEGER PRIMARY KEY,
    customer_uid        TEXT    NOT NULL UNIQUE,
    signup_ts           TEXT    NOT NULL,         -- 'YYYY-MM-DD HH:MM:SS'
    country             TEXT    NOT NULL,
    region              TEXT    NOT NULL,
    city                TEXT    NOT NULL,
    acquisition_channel TEXT    NOT NULL,         -- paid_search|paid_social|organic_search|email|referral|direct|affiliate
    first_device        TEXT    NOT NULL,         -- mobile|desktop|tablet
    is_business         INTEGER NOT NULL DEFAULT 0
);

-- ---------------------------------------------------------------------
-- 2. ТРАНЗАКЦИИ
-- ---------------------------------------------------------------------

-- status: delivered | shipped | processing | cancelled
-- ВАЖНО: cancelled-заказы НЕ являются выручкой. Все денежные запросы
-- фильтруют status <> 'cancelled' — это самая частая ошибка в таких витринах.
CREATE TABLE orders (
    order_id      INTEGER PRIMARY KEY,
    order_uid     TEXT    NOT NULL UNIQUE,
    customer_id   INTEGER NOT NULL REFERENCES customers(customer_id),
    order_ts      TEXT    NOT NULL,
    status        TEXT    NOT NULL CHECK (status IN ('delivered','shipped','processing','cancelled')),
    channel       TEXT    NOT NULL,               -- канал сессии, в которой произошёл заказ
    device        TEXT    NOT NULL,
    ship_country  TEXT    NOT NULL,
    shipping_cost REAL    NOT NULL DEFAULT 0,     -- РАСХОД магазина, вычитается из маржи
    promo_code    TEXT,                           -- NULL = заказ без промокода
    delivered_ts  TEXT                            -- NULL, пока не доставлен
);

-- discount_pct — скидка на позицию (0.00 .. 0.45).
-- Чистая выручка позиции = quantity * unit_price * (1 - discount_pct).
CREATE TABLE order_items (
    order_item_id INTEGER PRIMARY KEY,
    order_id      INTEGER NOT NULL REFERENCES orders(order_id),
    product_id    INTEGER NOT NULL REFERENCES products(product_id),
    quantity      INTEGER NOT NULL CHECK (quantity > 0),
    unit_price    REAL    NOT NULL,               -- цена продажи до скидки
    unit_cost     REAL    NOT NULL,               -- снимок себестоимости
    discount_pct  REAL    NOT NULL DEFAULT 0
);

CREATE TABLE payments (
    payment_id INTEGER PRIMARY KEY,
    order_id   INTEGER NOT NULL REFERENCES orders(order_id),
    method     TEXT    NOT NULL,                  -- card|paypal|apple_pay|bank_transfer|gift_card
    amount     REAL    NOT NULL,
    paid_ts    TEXT    NOT NULL,
    status     TEXT    NOT NULL CHECK (status IN ('captured','failed','refunded'))
);

-- Возвраты на уровне ПОЗИЦИИ, а не заказа: клиент может вернуть 1 из 3 штук.
-- Возвраты — главный «убийца» маржи в Apparel (см. отчёт, вопрос 2).
CREATE TABLE order_returns (
    return_id         INTEGER PRIMARY KEY,
    order_item_id     INTEGER NOT NULL REFERENCES order_items(order_item_id),
    return_ts         TEXT    NOT NULL,
    quantity_returned INTEGER NOT NULL CHECK (quantity_returned > 0),
    refund_amount     REAL    NOT NULL,
    reason            TEXT    NOT NULL            -- size_mismatch|damaged|not_as_described|changed_mind|late_delivery
);

-- ---------------------------------------------------------------------
-- 3. ПОВЕДЕНИЕ (для воронки)
-- ---------------------------------------------------------------------

-- customer_id NULL => анонимная сессия (пользователь не залогинен).
CREATE TABLE sessions (
    session_id     INTEGER PRIMARY KEY,
    session_uid    TEXT    NOT NULL UNIQUE,
    customer_id    INTEGER REFERENCES customers(customer_id),
    started_ts     TEXT    NOT NULL,
    device         TEXT    NOT NULL,
    traffic_source TEXT    NOT NULL,
    country        TEXT    NOT NULL,
    landing_page   TEXT    NOT NULL
);

-- Лог событий воронки. Шаги строго упорядочены:
--   session_start -> product_view -> add_to_cart -> checkout_start -> purchase
-- order_id заполнен ТОЛЬКО у события purchase => события и заказы сходятся 1:1.
CREATE TABLE events (
    event_id   INTEGER PRIMARY KEY,
    session_id INTEGER NOT NULL REFERENCES sessions(session_id),
    event_ts   TEXT    NOT NULL,
    event_type TEXT    NOT NULL CHECK (event_type IN
                 ('session_start','product_view','add_to_cart','checkout_start','purchase')),
    product_id INTEGER REFERENCES products(product_id),
    order_id   INTEGER REFERENCES orders(order_id)
);

-- Помесячные маркетинговые расходы по каналам -> CAC и окупаемость (06).
CREATE TABLE marketing_spend (
    spend_id     INTEGER PRIMARY KEY,
    channel      TEXT    NOT NULL,
    spend_month  TEXT    NOT NULL,                -- 'YYYY-MM'
    spend_amount REAL    NOT NULL,
    impressions  INTEGER NOT NULL,
    clicks       INTEGER NOT NULL,
    UNIQUE (channel, spend_month)
);

-- ---------------------------------------------------------------------
-- ИНДЕКСЫ: под join'ы по FK и оконные функции с PARTITION BY customer_id
-- ---------------------------------------------------------------------
CREATE INDEX idx_orders_customer      ON orders(customer_id);
CREATE INDEX idx_orders_ts            ON orders(order_ts);
CREATE INDEX idx_orders_status        ON orders(status);
CREATE INDEX idx_items_order          ON order_items(order_id);
CREATE INDEX idx_items_product        ON order_items(product_id);
CREATE INDEX idx_payments_order       ON payments(order_id);
CREATE INDEX idx_returns_item         ON order_returns(order_item_id);
CREATE INDEX idx_products_category    ON products(category_id);
CREATE INDEX idx_categories_parent    ON categories(parent_category_id);
CREATE INDEX idx_sessions_started     ON sessions(started_ts);
CREATE INDEX idx_events_session       ON events(session_id);
CREATE INDEX idx_events_type          ON events(event_type);
CREATE INDEX idx_customers_signup     ON customers(signup_ts);
CREATE INDEX idx_customers_channel    ON customers(acquisition_channel);
