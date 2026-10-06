use base 'consoletest';
use testapi;
sub run {
    assert_script_run('curl -O ' . data_url('console/payload.txt'));
}
1;
