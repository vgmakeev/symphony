---
id: task-5
title: 'Python: обратный отсчёт с ASCII-артом'
status: 'Review'
assignee: []
created_date: '2026-03-09'
labels:
  - test
  - python
dependencies: []
priority: high
---

## Description

Создать Python-скрипт `countdown.py` в корне workspace:

1. Принимает число N из аргументов (по умолчанию 5)
2. Выводит обратный отсчёт от N до 1
3. В конце выводит "LAUNCH!" в ASCII-арт стиле (простыми символами)
4. Каждое число выводится на отдельной строке в формате "T-{N}..."

Пример вывода для N=3:
```
T-3...
T-2...
T-1...

 _      _    _   _ _   _  ____ _   _ _
| |    / \  | | | | \ | |/ ___| | | | |
| |   / _ \ | | | |  \| | |   | |_| | |
| |  / ___ \| |_| | |\  | |___|  _  |_|
|_| /_/   \_\\___/|_| \_|\____|_| |_(_)
```

## Acceptance Criteria

- [ ] Файл `countdown.py` создан
- [ ] `python3 countdown.py` работает с дефолтом 5
- [ ] `python3 countdown.py 3` работает с аргументом
- [ ] Вывод содержит ASCII-арт
