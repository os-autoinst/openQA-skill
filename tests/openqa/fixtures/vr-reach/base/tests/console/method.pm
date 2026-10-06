use base 'consoletest';
sub run {
    my ($self, $args) = @_;
    $args->{instance}->unique_method_xyz;
}
1;
