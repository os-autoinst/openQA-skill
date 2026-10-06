package helpers;
use Exporter 'import';
our @EXPORT = qw(do_thing other);

=head2 do_thing

Does the thing, better.

=cut

sub do_thing {
    my $x = 2;
    return $x;
}

sub other {
    return 2;
}

1;
