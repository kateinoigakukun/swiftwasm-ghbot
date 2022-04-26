# ghbot

## How to deploy to C@E

```console
$ swift build --triple wasm32-unknown-wasi -c release
$ wasm-opt -Oz .build/release/ghbot.wasm -o .build/ghbot.wasm
$ fastly compute pack --wasm-binary=.build/ghbot.wasm
$ fastly compute deploy
```
