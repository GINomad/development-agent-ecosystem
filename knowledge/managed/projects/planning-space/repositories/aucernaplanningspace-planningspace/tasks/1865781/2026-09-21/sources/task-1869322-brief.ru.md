# 1869322 — Link report fields to variables

Эстимейт: Optimistic:200ч/50SP. Pessimistic:200ч/50SP. Dev/review/autotests152ч + QA48ч.

Вопросы: По desktop-коду и примерам уточнить rebind Range, overlap, copy/paste, удаление строк/листов и смену Regime; выбрать репрезентативные Standard/OLS шаблоны. Отдельного бизнес-решения о базовой механике не требуется.

Риски: Рассинхронизация named ranges и VariableList; потеря связей при structural edits; сложная матрица доступности атрибутов; POC вставляет values, а не persistent links.

Краткий план: 1. Зафиксировать desktop parity tests для Summary/Periodic и metadata. 2. Подключить каталог с Regime/search/All-Linked. 3. Создание cell/range links и атомарный save/reopen workbook+metadata. 4. Conditional attributes, headers, Placeholder Run, Unlink. 5. Structural edits и оба report types. Разбиение8+10+8+8+8+8SP.

Допущения:8ч/день,2SP/день,1SP=4ч. Это предварительные суммарные трудозатраты Dev+review+tests+QA. Сценарии scope не являются статистическими границами. Desktop — реализационный baseline.
