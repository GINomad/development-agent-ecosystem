# 1869339 — Support Range links: Date Range / Formula Range

Эстимейт: Optimistic:96ч/24SP. Pessimistic:96ч/24SP. Dev/review/autotests72ч + QA24ч.

Вопросы: Получить эталонные templates для fiscal year, mixed periodicity, summary и относительных/абсолютных формул. Бизнес-семантика уже определена desktop-кодом.

Риски: Различия SpreadsheetGear/DevExpress в формулах и named ranges; неверный seed Formula Range; ошибки изменения числа периодов и направления заполнения.

Краткий план: 1. Зафиксировать вход/выход desktop на образцах16ч. 2. Date Range с fiscal/mixed dates40ч. 3. Formula Range: первая periodic formula, resize, FillRight/FillDown40ч. В каждом срезе save/reopen и сравнение с существующим generator. Разбиение4+10+10SP.

Допущения:8ч/день,2SP/день,1SP=4ч. Это предварительные суммарные трудозатраты Dev+review+tests+QA. Сценарии scope не являются статистическими границами. Desktop — реализационный baseline.
