# Contributing to fire-cube

Thanks for taking a look. This is a small, single-file demo project, so the
bar for contributing is low — but a few things will save you a round trip.

## Setup

```bash
git clone https://github.com/iinoshirozheng/fire-cube.git
cd fire-cube
pixi install
pixi run build   # sanity-check it compiles -> dist/fire-cube
pixi run cube    # run it
```

If `pixi run` fails with `unable to locate module 'std'` right after cloning
or moving the folder, delete `.pixi/` and run `pixi install` again — the
environment bakes in absolute paths and doesn't survive being relocated.

## Mojo is a moving target

Mojo's syntax has changed significantly across versions (`fn` → `def`,
`alias` → `comptime`, `inout` → `mut`, etc.). Pretrained-model knowledge and
older blog posts/tutorials are frequently wrong for the current stable
release this project targets (`pixi.toml` pins `mojo >=1.0.0,<2`). Before
relying on remembered syntax, check the actual behavior against the
installed toolchain — `pixi run mojo run <scratch-file>` is the fastest way
to confirm a pattern compiles the way you expect.

## Before opening a PR

- Make sure `pixi run build` succeeds with no warnings you introduced.
- Actually run it (`pixi run cube`) and eyeball the output — this is a
  visual project; a change that compiles but looks wrong isn't done.
- Keep the diff focused. If you're tuning constants (fire cooling, corona
  strength, turbulence, lighting floor), a short note in the PR description
  on what you were going for helps more than the diff alone.
- If you touch the projection math (`plot_surface`'s `xp`/`yp`, the `× 2`
  aspect-ratio correction, or `CUBE_SIZE_RATIO`), mention what terminal size
  you tested at — it's easy to fix one aspect ratio and break another.

## Ideas that would be welcome

- Testing on Linux (`pixi.toml` pins `osx-arm64`, `linux-64`, and
  `linux-aarch64`, but CI only started exercising the Linux builds
  recently — bug reports from there are especially useful) or a tested
  `pixi workspace platform add` for a platform not listed yet.
- Alternative color palettes / lighting presets.
- Performance notes at very large terminal sizes.

## Reporting issues

Include your terminal size, terminal emulator, and (if the cube looks
wrong) a screenshot — subpixel-rendering bugs are usually invisible in a
text description.
