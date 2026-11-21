#!/bin/sh
cd "$(dirname "$0")" || exit 1
base=https://huggingface.co/leok7v
falcon=Falcon-H1-Tiny-Tool-Calling-90M-GGUF
for file in whistle/whistle.cact \
    $falcon/Falcon-H1-Tiny-90M-Tool-Calling-Q8_0.gguf \
    supertonic/supertonic-q4.safetensors; do
    to=models/leok7v/$file
    mkdir -p "$(dirname "$to")"
    [ -f "$to" ] || curl -fL -o "$to" \
        "$base/$(dirname "$file")/resolve/main/$(basename "$file")" || exit 1
done
du -sh models
