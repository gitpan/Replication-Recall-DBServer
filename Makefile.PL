use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile (
	       'NAME'	       =>  'Replication::Recall::DBServer',
	       'AUTHOR'        =>  'Ashish Gulhati <hash@netropolis.org>',
	       'ABSTRACT_FROM' =>  'DBServer.pm',
	       'VERSION_FROM'  =>  'DBServer.pm',
	       'PREREQ_PM'     =>  {
				    'DBI'                           =>  0,
				    'Carp'                          =>  0,
				    'POSIX'                         =>  0,
				    'File::Rsync'                   =>  0,
				    'Time::HiRes'                   =>  0,
				    'Data::Dumper'                  =>  0,
				    'Replication::Recall::Client'   =>  0,
				    'Replication::Recall::Server'   =>  0
				   },
	      );
