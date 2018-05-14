package Mojo::IOLoop::ReadWriteProcess::Shared::Memory;

use Mojo::IOLoop::ReadWriteProcess::Shared::Lock;
use Mojo::Base -base;

use Carp qw(croak confess);
use constant DEBUG => $ENV{MOJO_PROCESS_DEBUG};
use IPC::SharedMem;
use Config;
use IPC::SysV
  qw(ftok IPC_PRIVATE IPC_NOWAIT IPC_CREAT IPC_EXCL S_IRUSR S_IWUSR S_IRGRP S_IWGRP S_IROTH S_IWOTH SEM_UNDO S_IRWXU S_IRWXG);

our @EXPORT_OK = qw(shared_memory shared_lock semaphore);
use Exporter 'import';

has key => sub { Mojo::IOLoop::ReadWriteProcess::Shared::Semaphore::_genkey() };
has 'buffer';
has destroy        => 0;
has flags          => S_IRWXU() | S_IRWXG() | IPC_CREAT();
has _size          => 10 * 1024;
has _shared_memory => sub { $_[0]->_newmem() };
has _shared_size =>
  sub { $_[0]->_newmem((2 ^ shift->key) - 1, $Config{intsize}) };
has _lock => sub {
  Mojo::IOLoop::ReadWriteProcess::Shared::Lock->new(
    key => (2 ^ shift->key) + 1);
};

has dynamic_resize    => 1;
has dynamic_decrement => 1;
has dynamic_increment => 1;

sub shared_lock   { Mojo::IOLoop::ReadWriteProcess::Shared::Lock->new(@_) }
sub semaphore     { Mojo::IOLoop::ReadWriteProcess::Shared::Semaphore->new(@_) }
sub shared_memory { __PACKAGE__->new(@_) }

sub new {
  my $s = shift->SUPER::new(@_);
  confess 'Could not allocate shared size memory ' . $s->key
    unless $s->_shared_size;
  $s->_loadsize;
  confess 'Could not allocate shared memory with key ' . $s->key
    unless $s->_shared_memory;
  return $s;
}


sub _encode_content { $_[0]->buffer(unpack 'H*', $_[0]->buffer()) }
sub _decode_content { $_[0]->buffer(pack 'H*',   $_[0]->buffer()) }

sub _writesize {
  my $self = shift;
  my $size = shift;
  $self->_shared_size()->write(pack('I', $size), 0, $Config{intsize});
}

sub _readsize {
  my $self = shift;
  my $s = $self->_shared_size()->read(0, $Config{intsize});
  return unpack('I', $s);
}

sub _loadsize {
  my $s        = $_[0]->_readsize;
  my $cur_size = $_[0]->_size;
  $s = $_[0]->_size if $s == 0;
  $_[0]->_size($s =~ /\d/ ? $s : $_[0]->_size);
  $_[0]->_writesize($_[0]->_size) and $_[0]->_shared_memory($_[0]->_newmem)
    if $s != $cur_size;

  warn "[debug:$$] Mem size: " . $_[0]->_size if DEBUG;
}

sub _reload {
  $_[0]->_shared_memory($_[0]->_newmem);
  do { $_[0]->_shared_memory($_[0]->_newmem) }
    unless (defined $_[0]->_shared_memory);
}

# Must be run in a locked section
sub _sync_size {
  warn "[debug:$$] Sync size for content ("
    . length($_[0]->buffer)
    . ") vs currently allocated ("
    . $_[0]->_size . ")"
    if DEBUG;

  $_[0]->_shared_memory->detach();
  1 unless $_[0]->_safe_remove;
  $_[0]->_size(length $_[0]->buffer);
  $_[0]->_reload;
  $_[0]->_writesize($_[0]->_size) if $_[0]->_shared_memory;
}

sub save {
  warn "[debug:$$] Writing data : " . $_[0]->buffer if DEBUG;

  $_[0]->_encode_content;

  eval {
    # Resize
    $_[0]->_sync_size
      if (
      $_[0]->dynamic_resize && (
        (
          $_[0]->dynamic_increment
          && (defined $_[0]->buffer && length $_[0]->buffer > $_[0]->_size)
        )    # Increment
        || ($_[0]->dynamic_decrement
          && (defined $_[0]->buffer && $_[0]->_size > length $_[0]->buffer)
        )    # Decrement
      ));

    $_[0]->_writesize($_[0]->_size);

    $_[0]->_shared_memory()->write($_[0]->buffer, 0, $_[0]->_size);
  };

  warn "[debug:$$] Error Saving data : $@" if $@ && DEBUG;

  $_[0]->_shared_memory->detach() if $_[0]->_shared_memory;
  return if $@;
  return 1;
}

sub _newmem {
  IPC::SharedMem->new(
    $_[1] // $_[0]->key(),
    $_[2] // $_[0]->_size,
    $_[0]->flags
  );
}

sub load {

  eval {
    $_[0]->_loadsize;
    warn "[debug:$$] Reading " . $_[0]->_size if DEBUG;
    $_[0]->_reload;
    $_[0]->_shared_memory->attach();
    $_[0]->buffer($_[0]->_shared_memory()->read(0, $_[0]->_size));
    $_[0]->_decode_content;
  };

  warn "[debug:$$] Error Loading data : $@" if $@ && DEBUG;
  return if $@;
  return 1;
}

sub _safe_remove {
  my $self = shift;
  my $stat = $self->_shared_memory()->stat();
  if (defined($stat) && ($stat->nattch() == 0)) {
    $self->_shared_memory()->remove();
    return 1;
  }
  return 0;
}

sub remove {
  my $self = shift;
  $self->_shared_memory->detach();
  $self->_lock->remove;
  $self->_shared_size()->remove();
  return $self->_safe_remove;
}

sub clean {
  my $self = shift;
  $self->lock_section(sub { $self->buffer('')->save });
}

sub unlock {
  eval { $_[0]->save };
  shift->_lock->unlock(@_);
}

sub lock { my $s = shift; my $r = $s->_lock->lock(@_); $s->load; $r }
sub try_lock { $_[0]->_lock->try_lock() }

sub lock_section {
  my ($self, $fn) = @_;
  warn "[debug:$$] Acquiring lock (blocking)" if DEBUG;
  1 while $self->lock != 1;
  warn "[debug:$$] Lock acquired $$" if DEBUG;

  my $r;
  {
    local $@;
    $r = eval { $fn->() };
    $self->unlock();
    warn "[debug:$$] Error inside locked section : $@" if $@ && DEBUG;
  };
  return $r;
}

sub stat { shift->_shared_memory->stat }

sub DESTROY { $_[0]->remove if $_[0]->destroy() }

!!42;