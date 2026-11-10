// Sample text shown on first launch. Lines in [brackets] and lines starting with # are dimmed cues.

let defaultScriptEN = """
# This is demosufler
Hi. This text scrolls right under the camera, so you read while looking into the lens.
Click the pencil on the right and paste your own script. Lines in [brackets] and lines starting with # are dimmed: they are cues, not read aloud.
[PAUSE]
Change the speed with the slider or the up and down arrows. Next to it you see how long the whole text will take.
Space pauses the scroll. Record gives you a three second countdown and starts from the top.
"""

let defaultScriptRU = """
# Это demosufler
Привет. Этот текст едет прямо под камерой, а ты смотришь в объектив и читаешь.
Нажми на карандаш справа и вставь свой текст. Строки в [скобках] и строки с решёткой в начале показываются серым: это подсказки, их не читают вслух.
[ПАУЗА]
Скорость меняется ползунком или стрелками вверх и вниз. Рядом написано, за сколько прокрутится весь текст.
Пробел ставит прокрутку на паузу. Кнопка «Запись» даёт три секунды на подготовку и начинает с начала текста.
"""

func defaultScript(for lang: Lang) -> String {
    lang == .ru ? defaultScriptRU : defaultScriptEN
}
