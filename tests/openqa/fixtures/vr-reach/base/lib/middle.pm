package middle;
use helpers qw(do_thing);
our @EXPORT = qw(mid_call);

sub mid_call {
    do_thing();
}

1;
