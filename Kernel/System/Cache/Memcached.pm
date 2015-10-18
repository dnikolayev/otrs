package Kernel::System::Cache::Memcached;

#Memcached Cache module for OTRS 4.x and 5.x - Memcached module for OTRS cache
#To run it, please add this file to Kernel/System/Cache directory of your OTRS
#And add your configuration of Memcahced to Kernel::Config (Config.pm):
#
#$Self->{Memcached} = {'Servers' => ['127.0.0.1:11211'], 'Parameters' => {'compress_threshold' => 10_000, 'utf8'=>1}}; 
#
#based on code of Paweł Bogusławski made for 3rd version (https://dev.ib.pl/ib/otrs/commit/4e855eba20f7deb655a6b0742b2059f5d842c8a2)
#left most of his comments inside as is and add some mine ones :)


use strict;
use warnings;

use Cache::Memcached::Fast;
use Encode;
use Encode::Locale;
use Digest::MD5 qw();
use Time::HiRes qw();
use Data::Dumper;
use vars qw(@ISA);

our @ObjectDependencies = (
    'Kernel::Config',
    'Kernel::System::Encode',
    'Kernel::System::Log',
    'Kernel::System::Main',
);


sub new {
    my ( $Type, %Param ) = @_;

    my $Self = {%Param};
    bless( $Self, $Type );

    # check needed objects
    #die Dumper($Self);
    $Self->{ConfigObject} = $Kernel::OM->Get('Kernel::Config');
    $Self->{LogObject} = $Kernel::OM->Get('Kernel::System::Log');
    $Self->{MainObject} = $Kernel::OM->Get('Kernel::System::Main');
    $Self->{EncodeObject} = $Kernel::OM->Get('Kernel::System::Encode');

    # get memcached connection parameters and open connection to cache
    # Please add you configuration of memcached in your Config.pm like this:
    # $Self->{Memcached} = {'Servers' => ['127.0.0.1:11211'], 'Parameters' => {'compress_threshold' => 10_000, 'utf8'=>1}}; 
    $Self->{Config} = $Self->{ConfigObject}->{Memcached};

    if ($Self->{Config} && $Self->{Config}->{Servers} && $Self->{Config}->{Parameters}) {
        my $InitParams = {
            servers => $Self->{Config}->{Servers},
            %{ $Self->{Config}->{Parameters} },
        };

        $Self->{MemcachedObject} = Cache::Memcached::Fast->new($InitParams);

        if (!$Self->{MemcachedObject}) {
            $Self->{LogObject}->Log(
                Priority => 'error',
                Message  => "Unable to initialize memcached connector: $!",
            );
        }
    }
    else {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => 'Memcached enabled but no valid Cache::Module::Memcached configuration found!',
        );
    }

    return $Self;
}

sub Set {
    my ( $Self, %Param ) = @_;

    for (qw(Type Key Value TTL)) {
        if ( !defined $Param{$_} ) {
            $Self->{LogObject}->Log( Priority => 'error', Message => "Need $_!" );
            return;
        }
    }

    return if !$Self->{MemcachedObject};

    # get memcached key name for given Type and Key
    my $MemcachedKeyName = $Self->_getMemcachedKeyName(
        %Param,
        InitNamespaceOnError => 1,
    );
    return if !$MemcachedKeyName;

    # Problems occured when using absolute TTLs /time()+$Param{TTL}/ and
    # relative TTLs greater than memcached threshold /$Param{TTL}>2592000/
    # so we'll limit TTLs to 2592000 (30 days) here. Probably bug in
    # Cache::Memcached::Fast. For TTL value details see memcached proto spec
    # https://github.com/memcached/memcached/blob/master/doc/protocol.txt
    if ( $Param{TTL} > 2592000 ) {
        $Param{TTL} = 2592000;
    }

    return $Self->{MemcachedObject}->set(
        $MemcachedKeyName,
        $Param{Value},
        $Param{TTL}
    );
}

sub Get {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for (qw(Type Key)) {
        if ( !defined $Param{$_} ) {
            $Self->{LogObject}->Log( Priority => 'error', Message => "Need $_!" );
            return;
        }
    }

    return if !$Self->{MemcachedObject};

    # get memcached key name for given Type and Key; do not initialize
    # namespace in case of namespace reading error (namespace init after
    # simple communication errors would cause same effect as CleanUp
    # on this object data type)
    my $MemcachedKeyName = $Self->_getMemcachedKeyName(
        %Param,
        InitNamespaceOnError => 0,
    );
    return if !$MemcachedKeyName;

    return $Self->{MemcachedObject}->get($MemcachedKeyName);
}

sub Delete {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for (qw(Type Key)) {
        if ( !defined $Param{$_} ) {
            $Self->{LogObject}->Log( Priority => 'error', Message => "Need $_!" );
            return;
        }
    }

    return if ( !$Self->{MemcachedObject} );

    # get memcached key name for given Type and Key
    my $MemcachedKeyName = $Self->_getMemcachedKeyName(
        %Param,
        InitNamespaceOnError => 1,
    );
    return if !$MemcachedKeyName;

    return $Self->{MemcachedObject}->delete($MemcachedKeyName);
}

sub CleanUp {
    my ( $Self, %Param ) = @_;

    return if !$Self->{MemcachedObject};

    # memcached expires data automatically
    return 1 if $Param{Expired};

    if ( $Param{Type} ) {
        # Invalidate namespace in cache by incrementing it; memcached will
        # take care of removing invalidated keys (LRU). In case of incrementing
        # error try to create new namespace.
        if (!$Self->{MemcachedObject}->incr('Namespace:' . $Param{Type}, 1)) {
            my $Miliseconds = int(Time::HiRes::gettimeofday() * 1000);
            if (!$Self->{MemcachedObject}->add('Namespace:' . $Param{Type}, $Miliseconds)) {
                $Self->{LogObject}->Log(
                    Priority => 'error',
                    Message  => "Error deleting objects of type $Param{Type} in memcached!",
                );
            }
        }

        return 1;
    }
    else {
        # flush all the cache if no type specified
        return $Self->{MemcachedObject}->flush_all();
    }
}

=item _getMemcachedKeyName()

Use MD5 digest of Type::Namespace::Key for memcached key (memcached key max
length is 250). Namespace for given cache object type is taken from cache.
New namespace is created if namespace is not found. For this algo idea see
http://code.google.com/p/memcached/wiki/NewProgrammingTricks#Namespacing
We use miliseconds not microseconds because overflow in the "incr" memcached
command wraps around the 64 bit mark.

Returns mamcached key name if determined or nothing on error:

    my $PreparedKey = $Self->_getMemcachedKeyName(
        Type => 'CacheObjectTypeName',
        Key => 'KeyName',
        InitNamespaceOnError => 0,  # set 1 to initialize namespace if cannot be read
    );

=cut

sub _getMemcachedKeyName {
    my ( $Self, %Param ) = @_;

    # try to find namespace for given key object type
    my $MemcachedNamespace = $Self->{MemcachedObject}->get('Namespace:' . $Param{Type});

    # if namespace not found - if allowed, create new one using miliseconds since the epoch
    if (!$MemcachedNamespace && $Param{InitNamespaceOnError}) {
        my $Miliseconds = int(Time::HiRes::gettimeofday() * 1000);

        if ($Self->{MemcachedObject}->add('Namespace:' . $Param{Type}, $Miliseconds)) {
            # Get namespace from cache in case it was updated meanwhile
            $MemcachedNamespace = $Self->{MemcachedObject}->get('Namespace:' . $Param{Type});
        }
    }

    # return nothing if namespace cannot be found
    return if !$MemcachedNamespace;

    my $MemcachedKeyName = $Param{Type} . ':' . $MemcachedNamespace . ':' . $Param{Key};
    $Self->{EncodeObject}->EncodeOutput( \$MemcachedKeyName );
    $MemcachedKeyName = Digest::MD5::md5_hex($MemcachedKeyName);
    return $MemcachedKeyName;
}

1;

