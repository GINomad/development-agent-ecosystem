# Report Designer 1865781 — анализ требований и оценка

> **Актуальная договорённость о сценариях:** optimistic = desktop parity (376ч/94SP по PBI;768ч/192SP полный Feature). Pessimistic = первоначальная трактовка требований (408ч/102SP по PBI;800ч/200SP полный Feature). Подробнее: estimation-scenarios-1865781.ru.md. Ранее исключённый из реализации cell-input вариант сохранён как pessimistic-сценарий оценки.

> **Решение пользователя, 21 сентября 2026:** цель — перенести существующую desktop-функциональность в веб. Desktop-код и воспроизводимое поведение являются эталоном для бизнес-семантики; неполные мокапы и противоречащие описания не вводят новое поведение. Основная оценка: **376 ч / 94 SP** для четырёх текущих PBI и **768 ч / 192 SP** для полного Feature. Исторический вариант нового Discount Rate cell input ниже больше не является активным вариантом scope. Неизвестные в desktop детали проверяются по реализации/тестам, без повторного запроса бизнес-решения там, где parity однозначна. Архитектура веб-хостинга, deployment и фактическая capacity остаются отдельными инженерными вопросами.
Дата: 21 сентября 2026. Анализ для планирования; ADO, код и общая база знаний не изменялись. Участвовали три агента: история POC/независимая оценка, проверенные знания, код PlanningSpace.

## Результат

Четыре существующие PBI покрывают только часть Feature. Для переноса существующего поведения ориентир — **376 часов / 94 SP** по четырём PBI и **768 часов / 192 SP** на полный Feature с недостающими работами. Если Discount Rate должен стать новым входом расчёта из ячейки, условный бюджет — **408 часов / 102 SP** по PBI, **800 часов / 200 SP** по Feature. Этот второй вариант требует согласования расширения расчётного контракта; пока это резерв для планирования, не готовое обязательство.

Расчёт: **8 ч = 1 человеко-день = 2 SP; 1 SP = 4 ч**. Размер рабочего дня — допущение, поскольку пользователь задал только SP/день. Линейная шкала, без Фибоначчи. Часы включают разработку, code review, целевые автотесты и QA. Это общие трудозатраты ролей, не календарная длительность. Исторические затраты на POC повторно не начислены. Внешнее ожидание команд не превращается в effort.

## Полнота и источники

Прочитаны текущие descriptions, acceptance criteria, custom scope/NFR, комментарии и связи:

| Work item | Тип | Ревизия | Состояние | Дочерние |
|---|---|---:|---|---|
| [1865781](https://quorumsoftware.visualstudio.com/Quorum/_workitems/edit/1865781) | Feature | 59 | New | четыре ниже |
| [1869322 — Link report fields to variables](https://quorumsoftware.visualstudio.com/Quorum/_workitems/edit/1869322) | User Story | 18 | New | нет |
| [1869334 — Configure template time-series orientation](https://quorumsoftware.visualstudio.com/Quorum/_workitems/edit/1869334) | User Story | 3 | New | нет |
| [1869339 — Support Range links](https://quorumsoftware.visualstudio.com/Quorum/_workitems/edit/1869339) | User Story | 3 | New | нет |
| [1869369 — Support Discount Rate links](https://quorumsoftware.visualstudio.com/Quorum/_workitems/edit/1869369) | User Story | 3 | New | нет |

Таким образом, вся иерархия состоит из пяти элементов. Дочерние элементы технически User Story; здесь называются PBI по запросу пользователя. У всех четырёх AC пусты, непустых комментариев нет, поле Story Points в raw fields отсутствует. У Feature Custom.EffortSize=5: единица не установлена, поэтому это НЕ принято за 5 SP или 5 спринтов.

Также прочитаны связанные 1869308 rev28, 1866883 rev3 и predecessor 1874388 rev13. Дополнительно проверены HTML-вложение и две встроенные картинки родительской задачи; у дочерних вложений нет. Картинки просмотрены визуально, HTML изучен по структуре и обработчикам. Подробные уточнения и ограничения — в attachments-review-1865781.ru.md; оценки сохранены.

Код: C:/Repos/PlanningSpaceSource/PlanningSpace, origin соответствует Aucerna/PlanningSpace, локальный HEAD db7f87c7209b5897bba21df7d98a0e0081b58cef. Свежесть относительно удалённой ветки не подтверждалась. Есть незакоммиченный прототип web editor; он не засчитан как поставленная функциональность. Новые тесты и сборки основного продукта в рамках анализа не запускались.

## Главные выводы по требованиям

### 1. Выбрать архитектуру и устранить конфликт scope

Feature описывает перенос WPF SpreadsheetGear в вебовый Angular-клиент. Predecessor 1874388 одновременно говорит об Office add-in platform. Это разные продукты и ограничения; необходимо записать решение в spike.

Рабочий DevExpress Spreadsheet POC использует server-rendered ASP.NET Core host. В PlanningSpace уже существует iframe/postMessage для просмотра отчётов, поэтому интеграционный путь реалистичен. Но custom NFR Feature требует Angular-совместимость «not requiring a separate framework shell». Нужно явно подтвердить допустимость server-rendered host/iframe. До решения это архитектурный gate, а не утверждение, что POC уже соответствует NFR.

Основной продукт: Angular 20.3, DevExtreme 24.1.7, сервер net10.0. POC Spreadsheet: ASP.NET Core 8 + DevExpress 24.2.5. Версии, лицензирование, callbacks и packaging нужно проверить в продуктовой среде; нельзя просто скопировать POC.

### 2. Discount Rate: описание противоречит существующему коду

1869369 предполагает, что набранное в ячейке значение становится входом discounting. В текущем report generator Rate1–Rate5 заполняются из DiscountRateValueMapping настроек генерации. Это выходные pseudo-variables. Атрибут DiscountRate у periodic link выбирает слот из mapping.

Доказательство: Fusion/Framework/ReportGenerator/PseudoVariableValueProvider/CommonPseudoVariableValueFactory.cs:16–20; PeriodicNumericVariableLinkPopulator.cs:103. Поэтому подтверждение работы пятью слотами не подтверждает новую обратную связь «ячейка → расчёт».

Нужно решение PO/Economics: сохраняем parity или вводим новый механизм? Для нового механизма необходимо определить приоритет конфликтующих значений нескольких ячеек одного слота, единицу процентов, пустые/ошибочные значения, формулы, момент чтения и взаимодействие с report options. Это затрагивает границу с report execution, объявленным вне scope Feature.

### 3. Formula Range: код позволяет заменить неопределённость конкретными AC

Существующий FormulaRangeVariableLinkPopulator сохраняет первую периодическую формулу, меняет размер диапазона по числу периодов и распространяет её через FillRight/FillDown. SUMMARY не является исходной формулой для размножения. Placeholder-надписи SUMMARY/FIRST VALUE/SECOND VALUE создаёт ReportTemplateSpreadsheetHelper.

Предложение: принять это поведение как parity и подтвердить на эталонном шаблоне с Economics/QA. Больше не нужно оценивать Formula Range как полностью неизвестный новый механизм. В 96 ч ниже оставлены 16 ч на walkthrough, AC и эталонные примеры, а не повторное исследование с нуля.

### 4. Migration — не просто XLSX roundtrip

В продукте хранятся отдельно workbook Template bytes и сериализованный VariableList. Связи опираются на named ranges и метаданные. StandardReportVariableLink.cs:411–433 использует legacy BinaryFormatter. EditableStandardReportDBRepository.cs:53 и reader:86 читают/пишут обе части.

Нужно сохранять workbook, named ranges и соответствующие link records. Потеря метаданных при успешном открытии XLSX всё равно означает сломанный шаблон. Следует проверить доверенные пути legacy-десериализации и не создавать новый публичный вход для произвольного BinaryFormatter payload.

### 5. Недостающие требования

Родительские AC10 (migration), AC11 (ribbon) и базовый editor host/save не представлены отдельными PBI. Требуется matrix возможностей Insert/Formulas/Data/Review/View, styling/headers, и согласованный corpus реальных шаблонов. Формулировка «full Report Template tab» не даёт ограниченного тестируемого объёма сама по себе.

Variable Groups остаются held до подтверждения существования и нужного поведения. Preview удалён из текущего Objective; не включён в оценку. Report execution/viewing, список шаблонов, folder CRUD, UI permissions, XML import/export и Edit Using Excel принадлежат другим feature и не включены.

## Оценка существующих PBI

| PBI | Dev + review + автотесты | QA | Всего | SP | Чел.-дни | Диапазон часов / SP |
|---|---:|---:|---:|---:|---:|---|
| 1869322 Linking | 152 | 48 | **200** | **50** | 25 | 144–280 / 36–70 |
| 1869334 Orientation | 24 | 8 | **32** | **8** | 4 | 24–48 / 6–12 |
| 1869339 Date + Formula Range | 72 | 24 | **96** | **24** | 12 | 64–152 / 16–38 |
| 1869369 Discount Rate — parity с текущим кодом | 32 | 16 | **48** | **12** | 6 | 32–64 / 8–16 |
| **Итого parity** | **280** | **96** | **376** | **94** | **47** | **264–544 / 66–136** |
| 1869369 — альтернативно новый cell input | 56 | 24 | **80** | **20** | 10 | 64–160 / 16–40 |
| **Итого с новым cell input вместо parity** | **304** | **104** | **408** | **102** | **51** | **296–640 / 74–160** |

80 ч — условный бюджет нового cell-input поведения при ограниченном переиспользовании существующего engine. Если нужны изменения генерации/модели расчётов за пределами обозначенного контракта, требуется новая оценка. Два варианта Discount Rate альтернативны, их нельзя складывать.

Числа являются инженерной оценкой, не уже существующей оценкой ADO и не измеренной производительностью команды. Диапазоны отражают неопределённость; сумма границ не является статистическим доверительным интервалом. Уверенность средняя для Orientation, средняя-низкая для Linking и Ranges, низкая для нового Discount input и migration.

## Разбиение на управляемые истории

Рекомендуемый максимум — 12 SP. Ниже все срезы не больше этого размера; новая нумерация условная, элементы ADO не создавались.

| Родитель | Предлагаемый законченный срез | SP | Часы |
|---|---|---:|---:|
| 1869322 | Реальный каталог, Regime, поиск, All/Linked | 8 | 32 |
| 1869322 | Economic link: создать, сохранить и открыть cell/range link | 10 | 40 |
| 1869322 | Metadata pseudo-variables для двух типов отчётов | 8 | 32 |
| 1869322 | Редактирование WI, Real/Nominal, Type, DiscountRate | 8 | 32 |
| 1869322 | Placeholder Run + comparison metadata | 8 | 32 |
| 1869322 | Unlink, Linked-filter refresh, согласованные structural edits | 8 | 32 |
| 1869334 | Template-wide orientation + подтверждение очистки | 8 | 32 |
| 1869339 | Date Range с обеими ориентациями | 10 | 40 |
| 1869339 | Согласование Formula Range на эталонных шаблонах | 4 | 16 |
| 1869339 | Formula Range по подтверждённому существующему контракту | 10 | 40 |
| 1869369 parity | Rate1–5, multiple links, сохранение и проверка генерацией | 12 | 48 |

Если выбран новый cell-input: заменить последние 12 SP двумя срезами — контракт/валидация и управление ссылками 10 SP; подключение входов к согласованному расчётному контракту и сквозные тесты 10 SP. До решения PO эти срезы held.

Для многолистового копирования/перемещения, произвольных merged/protected ranges и сложного undo требуется отдельная матрица. Базовая оценка включает согласованный набор структурных изменений и отказ с понятной ошибкой для неподдерживаемых случаев; обещание неограниченного полного Excel parity в неё не входит.

## Предлагаемые acceptance criteria

Это предложения к refinement, а не уже утверждённые AC ADO.

**1869322:** Regime/search/All-Linked работают совместно с реальным каталогом. Economic и metadata leaves создают устойчивые ссылки, а не snapshots значений. Save/reopen сохраняет variable identity, cell/range, Name/Prompt/Type и редактируемые атрибуты. Изменение атрибутов не требует повторного linking. Placeholder Run сохраняет контекст выбранного run без запуска нового расчётного UI. Unlink убирает связь и обновляет Linked-filter. Поведение при смене Regime, удалении variable, overlap, вставке/удалении строк и переносе диапазона явно определено. Проверяются Standard и One Line Summary templates.

**1869334:** Orientation сохраняется на уровне шаблона; periodic links используют её после reopen. При существующих links Cancel ничего не меняет, Confirm атомарно меняет orientation и очищает согласованные категории links. Требуется уточнить, затрагиваются ли Date/Formula/Discount links, значения, формулы и форматирование. Текст задачи не разрешает автоматически стирать весь workbook.

**1869339:** Date Range имеет тип Periodic Date, даёт Total/периоды и reference для periodic links в обеих ориентациях. Тестируются изменение period count, ссылки после reopen и некорректные диапазоны. Formula Range воспроизводит эталонный WPF результат с первой периодической формулой, корректными относительными/абсолютными ссылками, отдельной summary-частью и FillRight/Down. Полноценный новый экран execution не требуется, но совместимость шаблона проверяется существующим generator.

**1869369 parity:** доступны ровно пять слотов, несколько ссылок на один слот разрешены, значения приходят из report options и совпадают с generator; атрибут DiscountRate выбирает нужный слот. Для cell-input варианта AC нельзя финализировать до решения source-of-truth, конфликтов и границы execution.

## Работы Feature без существующих PBI

| Дополнительный блок | Часы | SP | Срезы SP |
|---|---:|---:|---|
| Продуктовый Angular/editor host, текущий документ, open/save, lifecycle и версия документа | 96 | 24 | 8 + 8 + 8 |
| Migration workbook + links + named ranges + styles, corpus regression | 128 | 32 | 4 + 8 + 8 + 6 + 6 |
| Ribbon capability matrix, styling/headers, разрешённые функции и regression | 64 | 16 | 4 + 6 + 6 |
| Editor endpoint authorization, изоляция сессий, file/message validation | 48 | 12 | 6 + 6 |
| Deployment, runtime/license packaging, smoke, rollback, observability | 32 | 8 | 4 + 4 |
| AIDLC: согласование требуемого уровня и подготовка обязательных артефактов/gates | 24 | 6 | 6 |
| **Дополнительно** | **392** | **98** | |

AIDLC 24 ч — явное планировочное допущение; уровни и корпоративные deliverables не предоставлены. Не следует считать его гарантированным покрытием любой процедуры. Security и deployment выделены один раз; не добавлять поверх них ещё такой же «процент на безопасность». Review и обычное QA уже включены в строки.

Open/save здесь — инфраструктура целого документа. Сохранение link records в 1869322 — доменная часть той же операции, её нельзя повторно оценить внутри host. Права здесь — применение готового контракта, а не UI выдачи прав из 1869308. Новый collaboration/coauthoring не включён: нужно безопасное обнаружение конфликта версий и согласованное single-editor поведение.

**Full Feature parity: 768 ч = 192 SP = 96 человеко-дней. Новый cell-input: 800 ч = 200 SP = 100 человеко-дней.** Дополнительные блоки ориентировочно 264–624 ч; полный диапазон parity 528–1168 ч, нового варианта 560–1264 ч. Такой широкий диапазон — причина начать с решений архитектуры и migration corpus, а не обещать fixed-date delivery сейчас.

Эти итоги не включают реализацию соседней 1869308. В её комментарии есть чужая оценка Dev20days + QA5days; она не добавлена в наши суммы. Комментарий от 18 сентября сообщает, что её убрали из Phoenix 26.3 в пользу Currency Decks. Это реальная межкомандная зависимость.

## Что POC действительно снимает с риска

DevExpress POC fa96ce6dd400893bf3c14d30f46951f283024f17: 37 frontend + 17 .NET тестов и сборки по опубликованным результатам. Финальная browser-проверка подтвердили drop в I9:J10, после прокрутки C166, import → native edit → export → reopen. Это автоматизированные browser inputs в Edge, не широкая ручная host/browser-матрица.

POC пишет snapshots, а не persistent variable links. Drop перезагружает серверный документ: нужны UX/performance/regression checks. Не доказаны migration реальных шаблонов, tenant persistence, concurrency, production auth и rollout. DataGrid-вариант ограничен табличной схемой, не заменяет Spreadsheet; в финальной delivery-проверке есть незакрытый дефект собственного export/reimport (ID (read only) против ID).

Office.js POC ceecc01cb0fc4a32542d817154c4693289c3cfdb — отдельный технический путь, с double-click insertion и context command. Его ограничение task-pane → native Excel drag нельзя переносить на DevExpress web grid, где drop доказан.

База знаний проверена с учётом provenance: часть managed/projects/planning-space фактически относится к ps-excel-agent и ps-app-delfi. Эти сведения не приняты как архитектурные факты основного PlanningSpace. Использованы task-local проверенные outcomes POC и актуальный локальный код.

## Зависимости, вопросы и последовательность

| Решение/вопрос | Предлагаемый владелец | Что блокирует |
|---|---|---|
| Embedded server host/iframe допустим для custom Angular NFR? Какой component/version? | Архитектор, Economics frontend, Veles | Host и окончательные estimates |
| Rate1–5 — parity outputs или новые cell inputs? | PO + Economics engine | 1869369 и execution boundary |
| Подтвердить Formula Range по найденному WPF алгоритму | Economics engineer + QA | AC Formula Range |
| Контракт open/save/permissions при переносе 1869308 из PI | Veles + владельцы Report Management/Phoenix | Доступ к редактируемому шаблону |
| Что очищает orientation и что делает unlink со значениями? | PO + QA | 1869334, negative tests |
| Migration corpus, fallback, unsupported features и критерий no data loss | Клиентский/domain эксперт + QA | AC10 и migration budget |
| Structural edits, overlap, Regime change, invalid/missing variable | PO + инженер editor | 1869322 |
| Целевые размеры workbook, число links/variables, latency, browsers/DPI | Product + QA + platform | NFR и performance gate |
| AIDLC level, security review, deployment/license ownership | Engineering manager + Security/DevOps | Финальная capacity |

Последовательность: (1) закрыть component decision и бизнес-противоречия; (2) дать минимальный host/open/save контракт и orientation; (3) экономические ссылки и каталог, далее metadata/attributes/run; (4) Date и Formula ranges, Discount; (5) migration/ribbon corpus и сквозная регрессия; (6) security/deployment/AIDLC gates. Исследование migration и контракт с management-командой начинать сразу, иначе они станут поздними блокерами. Инженерные security controls закладывать с host, а не добавлять только в конце.

Для встреч сначала нужны владельцы, страны/часовые пояса и доступность участников. Встречи и ADO-изменения не выполнялись: запрос — анализ и оценка.

## Capacity и спринты по инструкции менеджера

Планировать effort, а не число календарных спринтов между start/finish. Для каждого участника:

availableHours = рабочие часы спринта − отпуск − праздники − прочие обязательные работы.

StoryCapacitySP = сумма availableHours / 4. Если AIDLC/security/deployment заведены отдельными оценёнными историями, они занимают этот же общий capacity; не вычитать их второй раз как overhead. Непересекающиеся отпуска/праздники не считать дважды. Для Dev и QA нужен отдельный bottleneck check, даже когда SP отражает суммарный effort.

Пример, не фактическая capacity команды: 2 разработчика + 1 QA, 10 дней, по 6 реально доступных часов в день после всех вычетов = 180 ч/спринт = 45 SP. Parity Feature 192 SP даёт арифметическую нижнюю границу 4.27 team-sprint equivalents, то есть минимум 5 календарных спринтов при идеальной загрузке. Но роли, зависимости и профиль QA могут увеличить срок; на основе одного деления дату не обещать.

Фактические team capacity, отпуска, праздники, дата старта и длина sprint не предоставлены/не проверены. Поэтому вместо фиктивного распределения по PI дана последовательность и sizing. Предпочитать один Feature в работе, разбитый на законченные истории; 50 SP Linking как единую sprint-story не оставлять.

## Локальные доказательства

- Снимок ADO в соседнем файле ado-snapshot.json: raw fields пяти элементов плюс тексты/comments связанного контекста.
- Production repository HEAD db7f87c7209b5897bba21df7d98a0e0081b58cef; Directory.Build.props:18; IPS/Palantir.IPS.AspNetCore.Spreadsheet; report-view.component.html:25 и .ts:53–60.
- CommonPseudoVariableValueFactory.cs:16–20; PeriodicNumericVariableLinkPopulator.cs:103; FormulaRangeVariableLinkPopulator.cs:42–77; ReportTemplateSpreadsheetHelper.cs:1356–1364.
- EditableStandardReportDBRepository.cs:53; StandardReportVariableLink.cs:411–433.
- Ecosystem task summaries: task-planning-space-excel-variable-poc-20260915, task-planning-space-variable-double-click-20260916, task-20260917-devextreme-grid-poc.
- Финальная проверка POC: C:/Users/okruk2/Documents/Codex/2026-09-17/g/work/delivery-verification-fa96ce6.md. Именно она фиксирует поздний DataGrid-дефект; более раннее completed не отменяет этот результат.

Отчёт не объявляет реализацию завершённой и не публикует гипотезы в shared knowledge. Предложенные AC и estimates требуют refinement владельцами, при этом весь запрошенный анализ и исходные доказательства сохранены локально.

## Дополнение по матрице поведения из кода

Настройки link не доступны безусловно: Working Interest относится к non-pseudo links, Real/Nominal — к currency units, DiscountRate — к periodic numeric DiscountedValues/NPV, PlaceholderRun — к business variables и определённым pseudo-variables. AC должны включать видимость/доступность и серверную валидацию по типам; единая форма со всеми активными полями не воспроизводит WPF.

Date Range должен учитывать fiscal year и mixed periodicity. Пример Total/2020/2021 в задаче недостаточен для матрицы совместимости. Эти проверки включены в предложенный parity scope; если требуются новые календарные правила, нужна отдельная оценка.

Существующий save требует update permission и business document lock. Web editor должен повторно использовать эти гарантии, а не заменить их только version field. Прототип в dirty working tree поддерживает загрузку Standard Report и ribbon, но Save намеренно disabled; отсутствуют DB persistence, business locks, linking и One Line Summary.

Полные относительные пути ключевых источников (база C:/Repos/PlanningSpaceSource/PlanningSpace):

- Fusion/Framework/ReportGenerator/VariableLinkPopulator/Implementation/FormulaRangeVariableLinkPopulator.cs:42
- Fusion/Framework/ReportGenerator/VariableLinkPopulator/Implementation/DateRangeVariableLinkPopulator.cs:23
- Fusion/Framework/ReportGenerator/VariableLinkPopulator/Implementation/PeriodicNumericVariableLinkPopulator.cs:103
- Fusion/Framework/ReportGenerator/PseudoVariableValueProvider/CommonPseudoVariableValueFactory.cs:16
- Fusion/Components/Administration/ViewModels/Reports/ReportVariableLinkSettingsViewModel.cs
- Fusion/Components/Administration/ViewModels/Reports/ReportTemplateEditorViewModel.cs:198, :356, :1570
- Fusion/Components/Administration/ViewModels/Reports/ReportTemplateSpreadsheetHelper.cs:1356
- Fusion/Framework/Report.Entities/Entities/EditableStandardReportEntity.cs:90, :103
- Fusion/Framework/Report.Entities/Entities/StandardReportVariableLink.cs:66, :411
- Fusion/Framework/Report.DataAccess/DBRepository/EditableStandardReportDBRepository.cs:53, :86
- Web/economics/src/app/report/resultset-view/report-view/report-view.component.html:25
- Web/economics/src/app/report/resultset-view/report-view/report-view.component.ts:53
- IPS/Palantir.IPS.AspNetCore.Spreadsheet/Palantir.IPS.AspNetCore.Spreadsheet.csproj:3, :63
- Fusion/Fusion.ServiceModel.Services.Web/Controllers/ReportSpreadsheetController.cs:48
- docs/report-template-web-editor-prototype.md (uncommitted prototype; не принятый baseline)


## Применение решения desktop → web

- **1869369:** Rate1–Rate5 отображают значения из report-generation options; атрибут DiscountRate выбирает слот для вычисления. Новый механизм чтения ставок из ячеек не реализуется. Основная оценка48ч/12SP.
- **1869339:** Formula Range повторяет существующий алгоритм первой периодической формулы и FillRight/FillDown; Date Range сохраняет fiscal/mixed-period semantics. Ранее выделенные16ч остаются на фиксацию примеров и регрессионных тестов, а не на выбор новой бизнес-логики. Основная оценка96ч/24SP.
- **1869322:** Summary/Periodic links, metadata, conditional attributes, Type, Unlink, Show Header и Above/Left переносятся по desktop. Отсутствие элемента в HTML-мокапе не является основанием убрать его. Основная оценка200ч/50SP.
- **1869334:** повторить desktop-подтверждение и фактический состав очищаемых links при смене orientation. Детали очистки проверять по обработчику и тестам; не придумывать новый вариант. Основная оценка32ч/8SP.
- Save, права и business locks, named ranges, link serialization и структурные операции проверять против desktop-сценариев. Для неоднозначных/зависящих от версии случаев нужен воспроизводимый пример; это задача анализа кода и regression corpus.
- Variable Groups и preview не добавляются как новые концепции из старых формулировок. Если подтверждённый desktop-сценарий в границах Report Template tab обнаружится, его включить в parity matrix и проверить влияние на бюджет.
- Существующее разделение feature сохраняется: Reports tab/management относится к1869308. Desktop parity не означает повторно включить соседний management scope в1865781.
- Числа768ч/192SP остаются предварительным бюджетом полного Feature, а не гарантией неограниченного spreadsheet parity. Matrix desktop-команд, реальные шаблоны и несовместимости компонента могут изменить объём. Теперь различия выясняются относительно конкретного desktop-эталона.

Закрыты вопросы о выборе бизнес-семантики Formula Range и Discount Rate. Вопросы web hosting/component compatibility, migration corpus, измеримых NFR, межкомандного open/save контракта и capacity сохраняются; desktop сам по себе не определяет эти вебовые условия.

