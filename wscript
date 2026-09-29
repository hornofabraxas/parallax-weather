#
# Parallax Weather watch face: standard Pebble SDK 3 waf script.
# SHOT=N, PERF_LOG=1 and HOLD_LIGHT=1 in the environment turn on the emulator harness, perf logging
# and a held backlight (see src/c/main.c).
#
import os.path

top = '.'
out = 'build'


def options(ctx):
    ctx.load('pebble_sdk')


def configure(ctx):
    ctx.load('pebble_sdk')


def build(ctx):
    ctx.load('pebble_sdk')
    binaries = []
    defines = ['SHOT=%d' % int(os.environ.get('SHOT', '0')), 'PERF_LOG=%d' % int(os.environ.get('PERF_LOG', '0')),
               'HOLD_LIGHT=%d' % int(os.environ.get('HOLD_LIGHT', '0'))]
    for p in ctx.env.TARGET_PLATFORMS:
        ctx.set_env(ctx.all_envs[p])
        ctx.set_group(ctx.env.PLATFORM_NAME)
        app_elf = '{}/pebble-app.elf'.format(ctx.env.BUILD_DIR)
        ctx.pbl_program(source=ctx.path.ant_glob('src/c/**/*.c'), target=app_elf, defines=defines)
        binaries.append({'platform': p, 'app_elf': app_elf})
    ctx.set_group('bundle')
    ctx.pbl_bundle(binaries=binaries,
                   js=ctx.path.ant_glob(['src/pkjs/**/*.js', 'src/pkjs/**/*.json']),
                   js_entry_file='src/pkjs/index.js')
