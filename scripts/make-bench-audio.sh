#!/usr/bin/env bash
# Builds a synthetic multi-language bench corpus with macOS' own TTS.
#
#   scripts/make-bench-audio.sh [out-dir]      # default bench/audio
#
# TTS speech is unrealistically clean, so these numbers are useful for
# COMPARING settings, not for judging absolute accuracy. Record your own clips
# into the same folder as <lang>-real-N.wav plus a matching .txt with what you
# actually said — the harness treats them identically and those are the ones
# that decide.
set -euo pipefail

out="${1:-bench/audio}"
mkdir -p "$out"

# Name of the first installed voice for a locale, "" if none. `say -v '?'` puts
# the locale in the last whitespace-separated field before the '#' comment, and
# voice names themselves contain spaces, so rebuild the name from the rest.
voice_for_locale() {
    say -v '?' | awk -F'#' -v want="$1" '{
        n = split($1, part, " ")
        if (part[n] != want) next
        name = part[1]
        for (i = 2; i < n; i++) name = name " " part[i]
        print name
        exit
    }'
}

# preferred voice, then any voice for the locale — novelty voices like "Bells"
# would otherwise win English by alphabet.
pick_voice() {
    local preferred="$1" locale="$2"
    if say -v '?' | grep -qF "$preferred "; then echo "$preferred"; return; fi
    voice_for_locale "$locale"
}

say_clip() {  # say_clip <name> <preferred-voice> <locale> <text>
    local name="$1" preferred="$2" locale="$3" text="$4"
    local voice
    voice="$(pick_voice "$preferred" "$locale")"
    if [ -z "$voice" ]; then
        echo "skip $name — no voice installed for $locale"
        return
    fi
    say -v "$voice" --file-format=WAVE --data-format=LEI16@16000 \
        -o "$out/$name.wav" "$text"
    printf '%s\n' "$text" > "$out/$name.txt"
    echo "$name  ($voice)"
}

# German and English get a short/medium/long spread, because the whole point of
# scaling audio_ctx is that cost should follow clip length.
say_clip de-short   Anna     de_DE "Bitte schick mir die Rechnung noch heute."
say_clip de-medium  Anna     de_DE "Ich habe den Termin auf Donnerstag verschoben, weil der Kunde am Mittwoch nicht kann."
say_clip de-long    Anna     de_DE "Wir haben die Aufnahme umgestellt, sodass das Mikrofon direkt in ein Array aus Fließkommazahlen schreibt, und die Erkennung läuft vollständig lokal auf dem Rechner, ohne dass irgendwelche Daten das Gerät verlassen."
say_clip en-short   Samantha en_US "Send me the invoice before lunch."
say_clip en-long    Samantha en_US "The recording pipeline converts every buffer to sixteen kilohertz mono floating point, and the whole transcription runs locally on the laptop without sending anything to a server."
say_clip fr-short   Thomas   fr_FR "Peux-tu relire le document avant la réunion de demain ?"
say_clip es-short   Mónica   es_ES "Envíame el informe antes de la reunión de mañana."
say_clip it-short   Alice    it_IT "Puoi rileggere il documento prima della riunione?"
say_clip pl-short   Zosia    pl_PL "Prześlij mi proszę fakturę jeszcze dzisiaj."
say_clip ja-short   Kyoko    ja_JP "明日の会議の前に資料を確認してください。"
say_clip th-short   Kanya    th_TH "กรุณาส่งเอกสารให้ฉันก่อนการประชุมพรุ่งนี้"

echo
echo "wrote $(ls "$out"/*.wav 2>/dev/null | wc -l | tr -d ' ') clips to $out"
