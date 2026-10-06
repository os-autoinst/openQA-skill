package exports;
use Exporter 'import';
our @EXPORT = qw(
    one
    two
);
sub one { 1 }
sub two { 2 }
1;
