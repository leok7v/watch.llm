# AGI

[![ci](https://github.com/leok7v/watch.llm/actions/workflows/ci.yml/badge.svg)](https://github.com/leok7v/watch.llm/actions/workflows/ci.yml)

A voice assistant on the Apple Watch. Open the app, speak, and hear
the answer. Three small models run on the watch itself: Whistle
hears, Falcon-H1 Tiny 90M answers and Supertonic speaks. The app
needs no phone and no server.

The app tells the time, sets and cancels a timer, reads the battery,
gets the weather and searches the web. The weather and the search
need a network.

The engines are the plain C code of
[talk](https://github.com/leok7v/talk).

## Build

The build needs Xcode with a watchOS simulator, and XcodeGen.

    git clone --recurse-submodules https://github.com/leok7v/watch.llm
    cd watch.llm
    ./models.sh
    xcodegen generate
    open Watch.xcodeproj

`models.sh` downloads the 3 model files, about 205 MB, into
`models/`. The build puts them into the app. Set your own development
team in `project.yml` for a run on a real watch.

## Check

    ./check.sh

The script builds the app, starts it in a watch simulator and checks
8 requests.

## Speed

On an Apple Watch SE 2 a turn takes about 6 s to 10 s. That time is
from the end of the voice to the first sound of the answer. The watch
has 2 cores, and each model uses both.

## Licence

Each model has its own licence, see the README of talk.
