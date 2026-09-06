use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
# Alien::Xrepo::Build - the build engine (mirrors the stage/hook shape of alienfile /
# Alien::Build, but every download/extract/build/gather stage is delegated to xrepo).
#
# Pipeline: configure -> probe -> install -> gather -> export (all hookable).
# Three property buckets mirror Alien::Build's meta_prop / install_prop / runtime_prop,
# all serialized as plain JSON so a run can be checkpointed and resumed.
#
class Alien::Xrepo::Build v0.9.5 {
    use Alien::Xrepo;
    use Alien::Xrepo::Build::Recipe;
    use Path::Tiny;
    use JSON::PP qw[encode_json decode_json];
    #
    my @STAGES = qw[configure probe install gather export test];
    #
    field $recipe       : param;               # Recipe object (or path/dir, normalized in ADJUST)
    field $root         : param //= undef;     # xrepo store root (XMAKE_PKG_INSTALLDIR)
    field $verbose      : param //= 0;
    field $repo         : param //= undef;     # injectable engine (spy-able)
    field $checkpoint   : param //= undef;     # state file path; enables resume
    field $snapshot     : param //= undef;     # write gathered runtime data as JSON here
    field $export_dir   : param //= undef;     # also xrepo-export each package into this dir
    field $probe_policy : param //= 'skip';    # skip|always|off
    field $resume       : param //= 0;
    #
    field $hooks        = {};                  # stage => [ coderef, ... ]
    field $meta_prop    = {};
    field $install_prop = {};
    field $runtime_prop = {};
    field $stage_done   = {};
    field $install_type = 'system';
    field $r            = undef;               # resolved Alien::Xrepo engine

    #
    ADJUST {
        unless ( ref $recipe ) {
            $recipe = Alien::Xrepo::Build::Recipe->new( defined $recipe && -d $recipe ? ( dir => $recipe ) : ( file => $recipe ), );
        }
        die "probe_policy must be skip|always|off" unless $probe_policy =~ /^(?:skip|always|off)$/;
        $r = $repo // Alien::Xrepo->new( root => $root, verbose => $verbose );
        if ($resume) {
            $self->_load_checkpoint;
            $self->configure( resume => 1 ) unless $stage_done->{configure};
        }
    }
    #
    method meta_prop ()    { return $meta_prop }
    method install_prop () { return $install_prop }
    method runtime_prop () { return $runtime_prop }
    method install_type () { return $install_type }
    method packages ()     { return $recipe->packages }
    method package_defs () { return $recipe->package_defs }
    method stage_done ()   { return $stage_done }
    method engine ()       { return $r }
    #
    # Hooks. A hook is invoked with ($self) immediately before its stage body.
    method register_hook ( $stage, $hook ) {
        die "Unknown stage '$stage'. Stages: @STAGES" unless grep { $_ eq $stage } @STAGES;
        die 'hook must be a coderef'                  unless ref $hook eq 'CODE';
        push @{ $hooks->{$stage} //= [] }, $hook;
        return;
    }
    method has_hook ($stage) { return $hooks->{$stage} && @{ $hooks->{$stage} } ? 1 : 0 }

    method run_hooks ($stage) {
        $self->$_($self) for @{ $hooks->{$stage} // [] };
        return;
    }
    #
    # Run the full pipeline.
    method run (%opts) {
        $self->configure(%opts);
        $self->probe;
        $self->install;
        $self->gather;
        $self->export;
        $self->test;
        return $self;
    }
    #
    # configure: freeze the recipe into meta_prop, fold ambient options over the
    # recipe defaults into install_prop->{profile}, register local recipe repos.
    method configure (%opts) {
        return if $stage_done->{configure};
        $self->run_hooks('configure');
        $meta_prop = {
            name         => $recipe->name,
            packages     => [ $recipe->packages ],
            package_defs => $recipe->package_defs,
            defaults     => $recipe->defaults,
            pkg_roots    => $recipe->pkg_roots,
            local_repos  => [ @{ $recipe->local_repos } ],
            hooks        => [ @{ $recipe->hooks } ],
        };
        my %profile = ( %{ $recipe->defaults }, %opts );
        $profile{configs} = { %{ $recipe->defaults->{configs} // {} }, %{ $opts{configs} // {} } }
            if ref $recipe->defaults->{configs} eq 'HASH' || ref $opts{configs} eq 'HASH';
        my $store;
        eval { $store = $r->_store_dir( installdir => $root ) };
        $store //= $root;
        $install_prop = { root => $root, profile => \%profile, probed => {}, store => $store, };

        for my $repo_def ( @{ $recipe->local_repos } ) {
            my $dir = path($repo_def)->absolute;
            my $nm  = 'alien-' . $dir->basename;
            next unless $dir->child('packages')->is_dir;
            say "[xrepo] registering local recipe repo $nm from $dir..." if $verbose;
            eval { $r->add_repo( $nm, $dir->stringify ) };
        }
        $install_type = 'system';
        $self->_checkpoint;
        $stage_done->{configure} = 1;
        return $self;
    }
    #
    # probe: for each package ask xrepo what version is already available in the
    # store. Results land in install_prop->{probed}. Under probe_policy 'skip' the
    # install stage treats a satisfied probe as a reason to skip reinstalling.
    method probe () {
        return if $stage_done->{probe};
        $self->run_hooks('probe');
        $install_prop->{probed} ||= {};
        if ( $probe_policy ne 'off' ) {
            for my $name ( $recipe->packages ) {
                my %opts     = $recipe->opts_for( $name, %{ $install_prop->{profile} // {} } );
                my $expected = $recipe->version_for($name);
                my $found;
                eval {
                    my $info = $r->info( $name, format => 'json', %opts );
                    $found = ref $info eq 'HASH' ? ( $info->{version} // $info->{package}{version} // undef ) : undef;
                };
                $install_prop->{probed}{$name} = { version => $found, satisfied => $self->_probe_satisfied( $found, $expected ) };
            }
        }
        $self->_checkpoint;
        $stage_done->{probe} = 1;
        return $self;
    }
    #
    # install: install each package in recipe order with its own version and
    # flags merged over the ambient profile. A failed package records an error
    # and the remaining packages still proceed (error isolation).
    method install () {
        return if $stage_done->{install};
        $self->run_hooks('install');
        $runtime_prop->{packages} ||= {};
        $runtime_prop->{errors}   ||= {};
        my $profile = $install_prop->{profile} // {};
        for my $name ( $recipe->packages ) {
            my %opts = $recipe->opts_for( $name, %$profile );
            if ( $self->_can_skip_install($name) ) {
                say "[xrepo] $name already satisfied by the store; skipping install" if $verbose;
                next;
            }
            my $version = $recipe->version_for($name);
            say "Installing $name" . ( defined $version && length $version ? " $version" : '' ) . '...' if $verbose;
            my $info;
            eval { $info = $r->install( $name, $version, %opts ); };
            if ($@) {
                warn "[!] $name failed to install: $@\n";
                $runtime_prop->{errors}{$name} = "$@";
                next;
            }
            if ( ref $info eq 'Alien::Xrepo::PackageInfo' ) {
                $runtime_prop->{packages}{$name} = $info->_data_printer(undef);
                $install_type = 'share';
            }
        }
        $self->_checkpoint;
        $stage_done->{install} = 1;
        return $self;
    }
    #
    # gather: ensure every installable package has consumer-facing data in
    # runtime_prop, re-fetching anything missing (or marked binary) so the
    # runtime layer needs no other state.
    method gather () {
        return if $stage_done->{gather};
        $self->run_hooks('gather');
        $runtime_prop->{packages} ||= {};
        my $profile = $install_prop->{profile} // {};
        for my $name ( $recipe->packages ) {
            next if exists $runtime_prop->{packages}{$name} || exists $runtime_prop->{errors}{$name};
            my %opts = $recipe->opts_for( $name, %$profile );
            my $info;
            eval { $info = $r->fetch( $name, $recipe->version_for($name), %opts ); };
            if ($@) {
                warn "[!] $name could not be gathered: $@\n";
                $runtime_prop->{errors}{$name} //= "$@";
                next;
            }
            if ( ref $info eq 'Alien::Xrepo::PackageInfo' ) {
                $runtime_prop->{packages}{$name} = $info->_data_printer(undef);
                $install_type = 'share';
            }
        }
        $self->_checkpoint;
        $stage_done->{gather} = 1;
        return $self;
    }
    #
    # export: write the gathered runtime data as a hermetic-able snapshot (JSON)
    # and/or xrepo-export each package into a directory of choice.
    method export () {
        return if $stage_done->{export};
        $self->run_hooks('export');
        if ( my $dir = $export_dir ) {
            for my $name ( $recipe->packages ) {
                next                               if exists $runtime_prop->{errors}{$name};
                say "Exporting $name into $dir..." if $verbose;
                eval { $r->export( $name, $recipe->version_for($name), packagedir => path($dir)->child($name)->absolute ); };
                warn "[!] $name could not be exported: $@\n" if $@;
            }
        }
        if ($snapshot) {
            my $data = {
                dist_name    => $recipe->name,
                install_type => $install_type,
                pkg_roots    => $recipe->pkg_roots,
                packages     => $runtime_prop->{packages} // {},
                errors       => $runtime_prop->{errors}   // {},
            };
            path($snapshot)->parent->mkpath if defined $snapshot;
            path($snapshot)->spew_utf8( encode_json($data) . "\n" );
            say "Wrote runtime snapshot $snapshot" if $verbose;
        }
        $self->_checkpoint;
        $stage_done->{export} = 1;
        return $self;
    }
    #
    # test: only hooks (the engine performs no compile smoke test of its own).
    method test () {
        return if $stage_done->{test};
        $self->run_hooks('test');
        $stage_done->{test} = 1;
        return $self;
    }
    #
    method _version_for_pkg ($name)          { $recipe->version_for($name) }
    method _opts_for_pkg    ( $name, %opts ) { $recipe->opts_for( $name, %opts ) }
    #
    method _probe_satisfied ( $found, $expected ) {
        return 0 unless defined $found    && length $found;
        return 1 unless defined $expected && length $expected;
        return $found eq $expected;
    }
    #
    method _can_skip_install ($name) {
        return 0 unless $probe_policy eq 'skip';
        my $probe = $install_prop->{probed}{$name} // {};
        return 0 unless $probe->{satisfied};
        my %opts = $self->_opts_for_pkg( $name, %{ $install_prop->{profile} // {} } );
        return !$opts{force};
    }
    #
    # Persist stage state + props so a later `resume => 1` constructor can pick
    # up where an interrupted run left off.
    method _checkpoint () {
        return unless defined $checkpoint;
        path($checkpoint)->parent->mkpath;
        my $data = {
            install_type => $install_type,
            stage_done   => $stage_done,
            meta_prop    => $meta_prop,
            install_prop => $install_prop,
            runtime_prop => $runtime_prop,
        };
        path($checkpoint)->spew_utf8( encode_json($data) . "\n" );
        return;
    }
    #
    method _load_checkpoint () {
        return 0 unless defined $checkpoint && -e $checkpoint;
        my $data = eval { decode_json( path($checkpoint)->slurp_utf8 ) };
        return 0 unless ref $data eq 'HASH';
        $install_type = $data->{install_type} // 'system';
        $stage_done   = $data->{stage_done}   // {};
        $meta_prop    = $data->{meta_prop}    // {};
        $install_prop = $data->{install_prop} // {};
        $runtime_prop = $data->{runtime_prop} // {};
        return 1;
    }
    }
    #
    1;
