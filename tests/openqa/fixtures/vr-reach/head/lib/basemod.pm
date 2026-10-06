package basemod;
use base 'opensusebasetest';

sub post_fail_hook {
    my ($self) = @_;
    $self->SUPER::post_fail_hook;
    return;
}

1;
