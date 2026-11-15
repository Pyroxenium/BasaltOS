# Shale modules used by the package build

`compressor.lua`, `huffman.lua`, `lexer.lua` and `minifier.lua` are unchanged
copies from [Shale](https://github.com/Pyroxenium/Shale) (`src/shale`, commit
`13f7df9`). They are kept here so that building BasaltOS does not need a Shale
checkout.

`tools/pack/build.lua` uses them to strip, minify and compress; the matching
decoder lives in `os/system/boot/bpk.lua`. When these files are updated, run
`tools/build.ps1` and `tools/test.ps1`: the build unpacks every package with
the runtime that ships, so a mismatch between the two fails the build.
