# Проверка вложений 1865781 и дочерних PBI

Проверено 21 сентября 2026, дополнение к requirements-estimation-1865781.ru.md.

## Покрытие

У Feature 1865781 найден один AttachedFile: report-management-mockup.html, 47 944 байта, добавлен 3 сентября 2026, attachment ID d20c8d9d-c28e-4eee-9107-d7c7b37407dc. Также прочитаны две встроенные в description картинки: WPF Report Designer (da89635d-ad3a-49cc-b8f3-c74cc1fe2d20) и вебовый макет (32d32306-5a13-442b-bc3e-fdb1793a7bf0). В снимке ADO у 1869322, 1869334, 1869339, 1869369 нет AttachedFile и встроенных изображений.

Обе картинки визуально просмотрены. HTML полностью проанализирован по структуре экранов и JavaScript handlers. Интерактивные клики в браузере не выполнялись: browser runtime не стартовал из-за Windows1260. Это ограничивает только проверку фактического исполнения HTML, но не чтение его структуры и обработчиков. Вложения доступны в outputs рядом с отчётом.

## Что подтверждено и что меняется в анализе

1. **В одном макете объединены две feature.** Слева Reports/folders, контекстные меню и permissions blade; справа Report Template editor. В исходнике прямо указан комментарий: editor workspace from 1865781. Folder CRUD, Master List, Import/Export, Edit Using Excel и назначение permissions относятся к 1869308 по актуальному текстовому scope. Наличие этих кнопок во вложении 1865781 не переносит ownership автоматически.

2. **Редактор имеет устойчивую компоновку:** Save, имя и путь шаблона; ribbon tabs Report Template / Spreadsheet Home / Insert / Formulas / Data / Review / View; слева Variables с Search/Regime/All-Linked; справа workbook; внизу свойства выбранной связи. Это уточняет layout для host и 1869322, уже учтённых в оценке. Проверка save-state, переключения шаблона с unsaved changes и update-lock всё ещё нужна: макет её не задаёт.

3. **Summary Links и Periodic Links представлены отдельно.** В дереве есть обе группы, в таблице отдельный Summary Link с <VALUE> и Periodic Link с Total/2020/2021. Для 1869322 нужно явно записать acceptance для обеих разновидностей, включая типы и доступность атрибутов. Summary Link нельзя смешивать с Formula Range <SUMMARY>: это разные понятия.

4. **Заголовки, Type и Unlink потеряны в веб-макете.** На WPF screenshot видны Show Header + Above/Left, Type=Values и Unlink; в HTML varbar их нет. При этом они требуются текущим scope. Нужно добавить их в web design/AC или явно согласовать исключение. Оценку не увеличиваю автоматически: редактирование атрибутов/unlink и styling/headers уже были в объёме прежнего отчёта.

5. **Range присутствует как свойство выбранного link.** WPF показывает диапазон и соседнюю кнопку выбора, HTML показывает фиксированное значение ='Cash Flow'!$C$7:$C$9. Web mockup не определяет, является ли Range editable и можно ли перепривязать существующий link. Требуется уточнить: достаточно показывать адрес и создавать link на выбранный range, либо нужен отдельный механизм редактирования адреса с валидацией. Второй вариант нельзя считать подтверждённым только по картинке.

6. **Мокап не разрешает конфликт Discount Rate.** Значения Rate1–5 (0,10,15,18,20) — жёстко заданный текст в HTML table. Ячейки не являются input/contenteditable, расчётного обработчика нет. Свойство Discount Rate в varbar тоже div, класс editable меняет оформление. Поэтому картинка не доказывает «введённая ставка управляет расчётом». Остаются два сценария прежней оценки: parity 48ч/12SP или условный новый cell input 80ч/20SP.

7. **Orientation и Formula Range не детализированы.** Нет диалога смены ориентации, destructive confirmation, выбора Date/Formula Range и их настройки. Группа Ranges и нарисованные годы не являются acceptance для fiscal/mixed periods. По этим PBI применяются текст задачи и найденная семантика кода; открытые вопросы не закрыты.

8. **Мокап не полный список metadata.** В нём нет явно показанных Comparison Calculation Settings и Incremental Project Info, которые есть в обновлённой 1869322 rev18. Вложение старше этой редакции истории; отсутствие ветки в эскизе не означает исключение из scope.

9. **Картинка включает merged cells, стили, выделенную ячейку и форматированные блоки.** WPF reference дополнительно показывает formula bar, row/column headers, sheet tabs и scrollbars. Это усиливает необходимость настоящего Spreadsheet и matrix поддерживаемых функций. Простая HTML table/DataGrid такой контракт не обеспечивает. Migration layout/styles/named ranges остаётся отдельной работой.

10. **Standard/OLS parity макетом не доказана.** Функция selectReport(row,name,type,path) меняет только выбранную строку, имя и путь, параметр type не используется. Поэтому выбор MKB Test OLS на картинке не доказывает отдельного поведения One Line Summary Report. Оба типа нужны в AC и regression.

## Интерактивность HTML: что реализовано в исходнике

Обработчики открывают Add/context menus, сворачивают folders, выбирают report, открывают/закрывают Permissions blade, меняют выбранную identity и текст Master List action. Большинство команд Rename/Copy/Cut/Import/Export/Delete/Edit Using Excel лишь закрывают меню. Save, spreadsheet ribbon, поиск/Regime, variable linking и пересчёт не реализованы. Это UI wireframe, а не рабочий технический POC, и его наличие не снижает реализационные трудозатраты.

Permissions blade дополнительно рисует Allow/Deny, Full Access, View Effective Permissions и Remove all existing permissions. Эти детали нужно согласовать в 1869308 с действующей security model; они не включаются автоматически в 1865781. Удаление или переназначение реальных permissions при анализе не выполнялось.

## Обновлённые AC-кандидаты

- 1869322: каталог различает Summary и Periodic links; selection существующего link синхронизирует нижнюю панель и range; атрибуты доступны по типу, read-only metadata остаются read-only.
- 1869322: веб-дизайн содержит Type (Values), Unlink, Show Header и Above/Left либо имеет явное согласованное решение по их расположению; отсутствие в mockup не отменяет текстовый scope.
- Host/save: перед сменой report при несохранённых изменениях определено поведение Save/Discard/Cancel; update permission и business lock проверяются сервером. Это предлагаемое уточнение, не якобы утверждённый сценарий макета.
- Migration/ribbon: проверяются merged cells, styles, named ranges, формулы и несколько листов на согласованном corpus. Мокап не является достаточным эталоном no-loss migration.
- Refinement question: допускается ли редактирование Range без пересоздания link? Как работает selection, если range содержит несколько различных links?

## Влияние на оценку

**Предыдущие числа сохраняются как предварительный бюджет:** 1869322 200ч/50SP; 1869334 32ч/8SP; 1869339 96ч/24SP; 1869369 parity48ч/12SP. Итого376ч/94SP по четырём PBI; полный Feature768ч/192SP. При новом Discount input — соответственно408ч/102SP и800ч/200SP.

Основание: mockup уточняет представление уже включённых функций, не подтверждает новую расчётную реализацию, не снимает migration и не переносит management scope. Для 1869322 нижнюю границу диапазона не стоит брать в обязательство до согласования Summary/Periodic, Range edit и непоказанных свойств. Если под требованием «как в мокапе» понимается также весь management UI, это расширение scope с отдельной оценкой 1869308, а не небольшая надбавка к редактору.

## Источники

- Родитель: https://quorumsoftware.visualstudio.com/Quorum/_workitems/edit/1865781
- AttachedFile d20c8d9d-c28e-4eee-9107-d7c7b37407dc: report-management-mockup.html, исходник строк 453–487 (menus), 491–550 (permissions), 572–645 (editor), 651–723 (handlers).
- Встроенные картинки сохранены как report-designer-wpf-reference.png и report-designer-web-mockup.png.
- Scope/current descriptions: ado-snapshot.json и основной отчёт.

## Уточнение пользователя после проверки вложений

Desktop-функциональность принята пользователем как эталон переноса. Поэтому пропущенные в mockup Type/Unlink/header controls сохраняются в scope, а статические Rate1–5 не вводят новый cell-input механизм. Основной бюджет:376ч/94SP по PBI,768ч/192SP по Feature. Альтернативный вариант нового discount input выше является историческим и больше не активен.
