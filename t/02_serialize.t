use utf8;
use Test::More;
use Test::DBIC;
use Storable qw(dclone);
use Modern::Perl;

use_ok 'DBIx::Class::Helper::Row::Serializer';
require_ok 'DBD::SQLite';

my $schema;

package MyApp::Schema::Foo;
use base  'DBIx::Class';
__PACKAGE__->load_components(qw( Core Helper::Row::Serializer ));
__PACKAGE__->table('foo');
__PACKAGE__->add_columns(
		id 	=> { data_type => 'int', is_auto_increment => 1 },
		name => { data_type => 'varchar', size => 50, is_nullable => 0},
	);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->has_many( bars => 'MyApp::Schema::Bar', 'foo_id');
sub schema{ $schema }
1;

package MyApp::Schema::Bar;
use base  'DBIx::Class';
__PACKAGE__->load_components(qw( Core Helper::Row::Serializer ));
__PACKAGE__->table('bar');
__PACKAGE__->add_columns(
		id 	=> { data_type => 'int', is_auto_increment => 1 },
		baz => { data_type => 'varchar', size => 50, is_nullable => 0},
		foo_id => { data_type => 'int', is_nullable => 0 },
	);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->has_many( geeks => 'MyApp::Schema::Gix', 'bar_id');
__PACKAGE__->belongs_to( foo => 'MyApp::Schema::Foo', 'foo_id' );
sub schema{ $schema }
1;

package MyApp::Schema::Gix;
use base  'DBIx::Class';
__PACKAGE__->load_components(qw( Core Helper::Row::Serializer ));
__PACKAGE__->table('gix');
__PACKAGE__->add_columns(
		id 	=> { data_type => 'int', is_auto_increment => 1 },
		age => { data_type => 'int', is_nullable => 0},
		bar_id => { data_type => 'int', is_nullable => 0 },
	);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->belongs_to( bar => 'MyApp::Schema::Bar', 'bar_id' );
sub schema{ $schema }
1;

package main;

$schema = Test::DBIC->init_schema(
        existing_namespace => 'MyApp::Schema',
        sqlt_deploy => 1,
        'sample_data' => [
            Foo => [
                ['id', 'name'],
                [1, 'my foo'],
                [2, 'real foo'],
            ],
            Bar => [
                ['id', 'baz', 'foo_id'],
                [3, 'bar-baz 3', 1],
                [4, 'bar-baz 4', 2],
            ],
            Gix => [
                ['id', 'age', 'bar_id'],
                [5, 30, 3],
                [6, 35, 3],
                [7, 40, 4],
            ],
        ],
    );

my @foo = $schema->resultset('Foo')->all;
my @bar = $schema->resultset('Bar')->all;
my @gix = $schema->resultset('Gix')->all;

is @foo, 2, 'foo records count';
is @bar, 2, 'bar records count';
is @gix, 3, 'gix records count';

my @expecteds =  (
   {
     'name' => 'my foo',
     'bars' => [
                 {
                   'baz' => 'bar-baz 3',
                   'geeks' => [
                        { 'age' => 30 },
                        { 'age' => 35 },
                    ],
                 }
               ]
   },
   {
     'bars' => [
                 {
                   'baz' => 'bar-baz 4',
                   'geeks' => [
                        { 'age' => 40 },
                    ],
                 }
               ],
     'name' => 'real foo'
   } );
   
my $i = 0;

FOO:
for my $foo ( @foo ){
    is_deeply $foo->serialize, $expecteds[$i++], "foo$i serialization";
}
my $foo1 = $schema->resultset('Foo')->unserialize( dclone($expecteds[0]) );
is ref($foo1), 'MyApp::Schema::Foo', 'unserialize result class';
is ref($foo1->insert), 'MyApp::Schema::Foo', 'insert a new Foo';
my $reserialize = $foo1->serialize;
is_deeply $reserialize, $expecteds[0], "unserialized & reserialiazed";

done_testing;