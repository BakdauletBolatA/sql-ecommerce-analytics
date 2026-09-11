#!/usr/bin/env bash
# Полная пересборка проекта: данные -> представления -> все восемь отчётов.
# Результаты складываются в results/ в виде текстовых таблиц.
set -euo pipefail
cd "$(dirname "$0")"

DB=data/ecommerce.db
PY=${PYTHON:-python3}

if [ ! -f "$DB" ]; then
  echo ">> База не найдена, генерирую (~15 сек)..."
  "$PY" data/generate_ecommerce_db.py
fi

echo ">> Создаю представления"
sqlite3 "$DB" < sql/00_setup_views.sql

mkdir -p results
for f in sql/0[1-8]_*.sql; do
  name=$(basename "${f%.sql}")
  echo ">> $name"
  sqlite3 "$DB" < "$f" > "results/${name}.txt"
done

echo ">> Проверки качества данных"
sqlite3 "$DB" < sql/99_data_quality_checks.sql > results/99_data_quality_checks.txt

echo ">> Готово. Результаты в results/"
