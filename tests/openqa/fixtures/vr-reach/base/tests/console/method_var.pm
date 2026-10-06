use base 'consoletest';
sub run {
    my ($self, $args) = @_;
    my $instance = $args->{instance};
    $instance->unique_method_xyz;
}
1;
