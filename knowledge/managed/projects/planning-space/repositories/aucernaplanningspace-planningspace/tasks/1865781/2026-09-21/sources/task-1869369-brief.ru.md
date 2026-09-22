# 1869369 — Support Discount Rate links

Эстимейт: Optimistic:48ч/12SP (Dev/review/autotests32ч + QA16ч). Pessimistic:80ч/20SP (56ч +24ч), исторический вариант нового cell input.

Вопросы: Для optimistic направление данных решено: Rate1–5 выводятся из report options. Если будет активирован pessimistic scope, потребуется определить конфликт нескольких cell inputs, проценты, пустые/формульные значения и приоритет относительно report options.

Риски: Текст ADO можно ошибочно прочитать как новый механизм расчёта; смешение отображаемых Rate slots и DiscountRate attribute; расширение scope report execution при cell-input варианте.

Краткий план: 1. Зафиксировать desktop output-slot contract в AC. 2. Перенести5 slots и multiple links. 3. Сохранить rate-selector настройки link. 4. Проверить save/reopen и генерацию с каждым slot. Optimistic одна история12SP; pessimistic при отдельном решении10+10SP.

Допущения:8ч/день,2SP/день,1SP=4ч. Это предварительные суммарные трудозатраты Dev+review+tests+QA. Сценарии scope не являются статистическими границами. Desktop — реализационный baseline.
