#include <stdint.h>
#include <stdio.h>

#include <mruby.h>
#include <mruby/array.h>
#include <mruby/error.h>
#include <mruby/irep.h>
#include <mruby/numeric.h>
#include <mruby/string.h>
#include <mruby/variable.h>

extern const uint8_t rmake_app[];

static void
set_argv(mrb_state *mrb, int argc, char **argv)
{
  int i;
  mrb_value ary = mrb_ary_new_capa(mrb, argc > 1 ? argc - 1 : 0);
  for (i = 1; i < argc; i++) {
    mrb_ary_push(mrb, ary, mrb_str_new_cstr(mrb, argv[i]));
  }
  mrb_define_global_const(mrb, "ARGV", ary);
  if (argc > 0 && argv[0]) {
    mrb_gv_set(mrb, mrb_intern_lit(mrb, "$0"), mrb_str_new_cstr(mrb, argv[0]));
  }
}

int
main(int argc, char **argv)
{
  int exit_code = 0;
  mrb_state *mrb = mrb_open();
  if (!mrb) {
    fprintf(stderr, "rmake: failed to initialize mruby\n");
    return 1;
  }

  set_argv(mrb, argc, argv);
  mrb_value result = mrb_load_irep(mrb, rmake_app);
  if (mrb->exc) {
    mrb_print_error(mrb);
    mrb_close(mrb);
    return 1;
  }

  if (mrb_integer_p(result)) {
    exit_code = (int)mrb_integer(result);
  } else if (!mrb_nil_p(result)) {
    exit_code = 1;
  }

  mrb_close(mrb);
  return exit_code;
}
