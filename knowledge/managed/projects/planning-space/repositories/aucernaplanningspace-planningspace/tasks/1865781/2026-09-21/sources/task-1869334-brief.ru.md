# 1869334 — Configure template time-series orientation

Эстимейт: Optimistic:32ч/8SP. Pessimistic:32ч/8SP. Dev/review/autotests24ч + QA8ч.

Вопросы: Проверить по desktop handler/tests точный состав очищаемых связей и сохранность значений, формул и formatting. Это проверка эталона, а не выбор нового поведения.

Риски: Частичная очистка metadata/named ranges; несохранённые изменения; ошибочное применение orientation только части periodic links.

Краткий план: 1. Перенести template-level orientation. 2. Воспроизвести desktop confirmation и очистку. 3. Согласованно сохранять workbook+links. 4. Проверить Cancel/Confirm, обе ориентации, reopen и связанные ranges. Одна история8SP.

Допущения:8ч/день,2SP/день,1SP=4ч. Это предварительные суммарные трудозатраты Dev+review+tests+QA. Сценарии scope не являются статистическими границами. Desktop — реализационный baseline.
