package helpers;
use Exporter 'import';
our @EXPORT = qw(do_thing other);

=head2 do_thing

Does the thing.

=cut

sub do_thing {
    my $x = 1;
    return $x;
}

sub other {
    return 2;
}

1;
