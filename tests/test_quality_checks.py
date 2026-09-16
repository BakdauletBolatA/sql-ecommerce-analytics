"""Проверка проверок: каждая обязана упасть на дефекте, который ищет.

В sql/99_data_quality_checks.sql двадцать проверок, и все они на приложенной
базе дают OK. Двадцать зелёных строк ничего не доказывают: проверка, которая
никогда не падала, не проверена. Здесь в копию базы вносится ровно один дефект
и утверждается, что именно та проверка становится красной, а остальные -
остаются зелёными.

Нужен только sqlite3 в PATH и pytest.
"""

from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
DB = ROOT / 'data' / 'ecommerce.db'
VIEWS = ROOT / 'sql' / '00_setup_views.sql'
CHECKS = ROOT / 'sql' / '99_data_quality_checks.sql'

FAIL_WORDS = ('ОШИБКА', 'РАСХОЖДЕНИЕ', 'ЕСТЬ ПРОПУСКИ')


def sqlite(db: Path, script: str | Path) -> str:
    text = script.read_text(encoding='utf-8') if isinstance(script, Path) else script
    done = subprocess.run(['sqlite3', str(db)], input=text, capture_output=True,
                          text=True, check=False)
    if done.returncode != 0:
        raise AssertionError(f'sqlite3 вернул {done.returncode}: {done.stderr.strip()}')
    return done.stdout


def run_checks(db: Path) -> str:
    sqlite(db, VIEWS)
    return sqlite(db, CHECKS)


def failing_lines(report: str) -> list[str]:
    return [line.strip() for line in report.splitlines()
            if any(word in line for word in FAIL_WORDS) and not line.startswith('===')]


@pytest.fixture
def db(tmp_path: Path) -> Path:
    copy = tmp_path / 'ecommerce.db'
    shutil.copy(DB, copy)
    return copy


# Один дефект - одна проверка. Текст в третьем поле должен встретиться в
# строке отчёта, которая стала красной.
DEFECTS = [
    ('позиция заказа без заказа',
     "INSERT INTO order_items (order_item_id, order_id, product_id, quantity, unit_price, "
     "unit_cost, discount_pct) VALUES (9000001, 9999999, 1, 1, 10, 5, 0);",
     'order_items -> orders'),
    ('позиция заказа с несуществующим товаром',
     "INSERT INTO order_items (order_item_id, order_id, product_id, quantity, unit_price, "
     "unit_cost, discount_pct) SELECT 9000002, MIN(order_id), 9999999, 1, 10, 5, 0 FROM orders;",
     'order_items -> products'),
    ('заказ без клиента',
     "INSERT INTO orders (order_id, order_uid, customer_id, order_ts, status, channel, device, "
     "ship_country, shipping_cost) VALUES (9000003, 'X-9000003', 9999999, '2025-01-01T10:00:00', "
     "'delivered', 'email', 'desktop', 'KZ', 0);",
     'orders -> customers'),
    ('платёж по несуществующему заказу',
     "INSERT INTO payments (payment_id, order_id, method, amount, paid_ts, status) "
     "VALUES (9000004, 9999999, 'card', 100, '2025-01-01T10:00:00', 'captured');",
     'payments -> orders'),
    ('возврат по несуществующей позиции',
     "INSERT INTO order_returns (return_id, order_item_id, return_ts, quantity_returned, "
     "refund_amount, reason) VALUES (9000005, 9999999, '2025-01-02T10:00:00', 1, 10, 'damaged');",
     'order_returns -> order_items'),
    ('событие без сессии',
     "INSERT INTO events (event_id, session_id, event_ts, event_type) "
     "VALUES (9000006, 9999999, '2025-01-01T10:00:00', 'product_view');",
     'events -> sessions'),
    ('товар без категории',
     "UPDATE products SET category_id = 9999999 WHERE product_id = (SELECT MIN(product_id) "
     "FROM products);",
     'products -> categories'),
    ('отрицательная цена',
     "UPDATE order_items SET unit_price = -1 WHERE order_item_id = "
     "(SELECT MIN(order_item_id) FROM order_items);",
     'неположительной ценой'),
    ('скидка 150%',
     "UPDATE order_items SET discount_pct = 1.5 WHERE order_item_id = "
     "(SELECT MIN(order_item_id) FROM order_items);",
     'скидка вне диапазона'),
    ('вернули больше, чем купили',
     "INSERT INTO order_returns (return_id, order_item_id, return_ts, quantity_returned, "
     "refund_amount, reason) SELECT 9000007, oi.order_item_id, '2026-01-01T10:00:00', "
     "oi.quantity + 5, 10, 'damaged' FROM order_items oi ORDER BY oi.order_item_id LIMIT 1;",
     'вернули больше, чем купили'),
    ('возврат раньше заказа',
     "UPDATE order_returns SET return_ts = '2000-01-01T00:00:00' WHERE return_id = "
     "(SELECT MIN(return_id) FROM order_returns);",
     'возврат раньше заказа'),
    ('доставка раньше заказа',
     "UPDATE orders SET delivered_ts = '2000-01-01T00:00:00' WHERE order_id = "
     "(SELECT MIN(order_id) FROM orders WHERE delivered_ts IS NOT NULL);",
     'доставка раньше заказа'),
    ('заказ без единой позиции',
     "INSERT INTO orders (order_id, order_uid, customer_id, order_ts, status, channel, device, "
     "ship_country, shipping_cost) SELECT 9000008, 'X-9000008', MIN(customer_id), "
     "'2025-01-01T10:00:00', 'cancelled', 'email', 'desktop', 'KZ', 0 FROM customers;",
     'заказы без единой позиции'),
    ('возврат по отменённому заказу',
     "UPDATE orders SET status = 'cancelled' WHERE order_id = (SELECT o.order_id FROM orders o "
     "JOIN order_items oi USING (order_id) JOIN order_returns r USING (order_item_id) LIMIT 1);",
     'возвраты по отменённым заказам'),
]


@pytest.mark.parametrize(('label', 'sql', 'expected'), DEFECTS,
                         ids=[d[0] for d in DEFECTS])
def test_a_check_turns_red_on_the_defect_it_looks_for(db: Path, label, sql, expected) -> None:
    sqlite(db, sql)
    red = failing_lines(run_checks(db))
    assert red, f'дефект «{label}» внесён, но все проверки остались зелёными'
    assert any(expected in line for line in red), (
        f'дефект «{label}» поймала не та проверка: {red}'
    )


def test_the_shipped_database_passes_every_check() -> None:
    assert failing_lines(run_checks(DB)) == []


def test_a_missing_purchase_event_breaks_the_reconciliation(db: Path) -> None:
    """Событий purchase должно быть ровно столько же, сколько живых заказов."""
    sqlite(db, "DELETE FROM events WHERE event_id = (SELECT MIN(event_id) FROM events "
               "WHERE event_type = 'purchase');")
    assert any('РАСХОЖДЕНИЕ' in line for line in failing_lines(run_checks(db)))


def test_a_changed_payment_breaks_the_money_reconciliation(db: Path) -> None:
    """Платёж должен сходиться с позициями заказа плюс доставка - до двух копеек."""
    sqlite(db, "UPDATE payments SET amount = amount + 1 WHERE payment_id = "
               "(SELECT MIN(payment_id) FROM payments);")
    report = run_checks(db)
    assert any('РАСХОЖДЕНИЕ' in line for line in failing_lines(report))
    assert re.search(r'\n\s*17647\s+1\s+1\.0', report), 'должно быть ровно одно расхождение'


def test_a_hole_in_the_calendar_is_found(db: Path) -> None:
    """Выпавший месяц ломает и когорты, и сезонность - его надо заметить до анализа."""
    sqlite(db, "DELETE FROM orders WHERE order_ts LIKE '2025-03%';")
    assert any('ЕСТЬ ПРОПУСКИ' in line for line in failing_lines(run_checks(db)))


def test_an_isolated_defect_makes_exactly_one_check_red(db: Path) -> None:
    """Дата доставки ни на что, кроме своей проверки, не влияет."""
    sqlite(db, "UPDATE orders SET delivered_ts = '2000-01-01T00:00:00' WHERE order_id = "
               "(SELECT MIN(order_id) FROM orders WHERE delivered_ts IS NOT NULL);")
    red = failing_lines(run_checks(db))
    assert len(red) == 1 and 'доставка раньше заказа' in red[0]


def test_a_defect_in_a_line_total_makes_the_money_check_red_as_well(db: Path) -> None:
    """А вот скидка 150% - не изолированный дефект, и это правильно: она меняет
    сумму позиции, поэтому платёж перестаёт сходиться с заказом. Проверки B и D
    ловят одно и то же событие с двух сторон."""
    sqlite(db, "UPDATE order_items SET discount_pct = 1.5 WHERE order_item_id = "
               "(SELECT MIN(order_item_id) FROM order_items);")
    red = failing_lines(run_checks(db))
    assert len(red) == 2
    assert any('скидка вне диапазона' in line for line in red)
    assert any('РАСХОЖДЕНИЕ' in line for line in red)


# -- то, что до SQL-проверок не доходит: схема не даёт записать --------------------

GUARDED = [
    ('количество <= 0',
     "UPDATE order_items SET quantity = 0 WHERE order_item_id = "
     "(SELECT MIN(order_item_id) FROM order_items);",
     'quantity > 0'),
    ('возврат нулевого количества',
     "UPDATE order_returns SET quantity_returned = 0 WHERE return_id = "
     "(SELECT MIN(return_id) FROM order_returns);",
     'quantity_returned > 0'),
    ('неизвестный статус заказа',
     "UPDATE orders SET status = 'refunded' WHERE order_id = (SELECT MIN(order_id) FROM orders);",
     'status IN'),
    ('неизвестный тип события',
     "INSERT INTO events (event_id, session_id, event_ts, event_type) SELECT 9000009, "
     "MIN(session_id), '2025-01-01T10:00:00', 'view' FROM sessions;",
     'event_type IN'),
]


@pytest.mark.parametrize(('label', 'sql', 'constraint'), GUARDED, ids=[g[0] for g in GUARDED])
def test_the_schema_refuses_the_value_before_any_check_runs(db: Path, label, sql, constraint):
    """Часть проверок из раздела B дублирует ограничения схемы: внести такой
    дефект в эту базу нельзя вовсе. Это не делает проверки лишними - витрину
    можно загрузить и мимо ограничений, - но проверяется здесь именно схема."""
    with pytest.raises(AssertionError, match='CHECK constraint failed') as error:
        sqlite(db, sql)
    assert constraint in str(error.value), 'sqlite обязан назвать сработавшее ограничение'
