#!/bin/sh
# Ставит номер сборки (CFBundleVersion) = число коммитов в git.
# Запускается Xcode при каждой сборке (фаза «Номер сборки из git» у цели OpenLuch).
#
# Зачем: раньше номер сборки был жёстко «1» в настройках проекта, и все сборки
# выглядели одинаково. Теперь каждый новый коммит даёт следующий номер, а по номеру
# из «Настроек» → «О приложении» можно найти, из какого коммита собрано приложение:
#   git rev-list --count HEAD        — номер текущего коммита
#   git log --reverse --oneline | sed -n 'Np'   — коммит с номером N
# Номер сборки по правилам Apple — только цифры (и точки), поэтому пометку
# «есть незакоммиченные изменения» в него не добавить — она пишется в журнал сборки.
#
# Версию (CFBundleShortVersionString, «0.1») скрипт НЕ трогает: её меняют вручную
# в Xcode (цель OpenLuch → General → Version), когда выходит заметная новая версия.

set -e

PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"

if BUILD_NUMBER=$(git -C "${SRCROOT}" rev-list --count HEAD 2>/dev/null); then
    :
else
    # Нет git или папка не репозиторий — оставляем номер из настроек проекта.
    echo "warning: git недоступен, номер сборки не изменён"
    exit 0
fi

if [ -n "$(git -C "${SRCROOT}" status --porcelain 2>/dev/null)" ]; then
    echo "note: есть незакоммиченные изменения — номер сборки ${BUILD_NUMBER} как у последнего коммита"
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${PLIST}"
echo "Номер сборки: ${BUILD_NUMBER}"
