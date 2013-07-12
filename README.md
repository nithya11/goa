Evolutionary Program Optimization
=================================

During compilation and linking, non-functional properties of software
such as running time and executable size may be optimized.  Current
techniques rely on operations which may be formally proven to preserve
program semantics.

Using a test-suite based definition of program behavior we are able to
apply non-semantic preserving mutations to software resulting in
program variants not reachable through semantic preserving operation.
Due to the inherent mutational robustness of software [1], many of
these mutations will change the runtime behavior of software without
changing the specification to which the software conforms.

Some program variants will have desirable non-functional properties
such as faster running times, reduced energy consumption or a smaller
executable size.  By assigning fitness to variants based on these
characteristics it is possible to optimize software.

Modern system emulators and profilers allow fine-grained monitoring of
aspects of program execution, such as energy consumption and
communication overhead, which may be difficult to predict a-priori.
This repository uses Graphite [2] and Linux perf [3] to measure
non-functional properties of program variants in an EC system for
software optimization.

This repository will hold three benchmarks suites used in this
investigation of evolutionary program optimization.  The PARSEC
benchmark suite [4] focuses on emerging workloads.  The Spec benchmark
suite [5] stresses a systems "processor, memory subsystem and
compiler", and a collection of warehouse compute applications.

Repository Layout
=================

        README | this file
         NOTES | working notes and reproduction instructions
       COPYING | standard GPLV3 License
    benchmarks | holds benchmark programs, input and output
           bin | shell scripts to run experiments and collect results
           etc | miscellaneous support files
       results | experimental results
           src | lisp source for main optimization programs

Installation and Usage
======================

The evolution toolkit which we'll use to evolve programs is written in
Common Lisp.  Each optimized program also requires a shell script test
driver, and a test harness (used to limit resources consumed by
evolved variants) is written in C.  Assuming you already have both
bash and a C compiler on your system, the following additional tools
will need to be installed.

1. Steel Bank Common Lisp (SBCL) [6] or Clozure Common Lisp (CCL) [7].

2. The Quicklisp [8] Common Lisp package manager which will be used to
   install all of the required lisp packages.  Follow the instructions
   on the Quicklisp site to install it.

3. Under the directory to which quicklisp has been installed (by
   default `~/quicklisp`), there will be a `local-projects` directory.
   Clone the following two git repositories into this directory.

        git clone git://github.com/eschulte/curry-compose-reader-macros.git
        git clone git://github.com/eschulte/software-evolution.git

   You will also need to symlink this repository into your
   `local-projects` directory.

        ln -s $(pwd) ~/quicklisp/local-projects/

   Finally, ensure Quicklisp has been added to your init file, and
   then use Quicklisp to register these newly cloned local projects.

        (ql:add-to-init-file)
        (ql:register-local-projects)

4. Once Quicklisp and these dependencies have all been installed, run
   the following to install the OPTIMIZE package and all of its
   dependencies.

        (ql:quickload :optimize)

5. Checkout the following tool for the protected execution of shell
   commands through the file system.  This serves to isolate the
   evolutionary process from the many errors thrown during extremely
   long-running optimization runs, the accumulation of which can
   occasionally stall the lisp process.  From the base of this
   directory run the following to clone sh-runner.

        git clone git://github.com/eschulte/sh-runner.git

6. At this point it is possible to run program optimization from the
   lisp REPL as described below.  To build a command line program
   optimization executable, install cl-launch [9] and then run make.

   The LISP environment variable may be set to `sbcl` or `ccl` to
   compile executables with Steel Bank Common Lisp or Clozure Common
   Lisp respectively.

Batch Optimization at the Command Line
--------------------------------------

At this point everything needed has been installed.  The following
steps walk through optimizing blackscholes from the command line to
reduce energy consumption.

1. Run the `optimize` executable once to view all of the optional
   arguments.

        ./bin/optimize -h

2. Compile blackscholes to assembly and generate the test input and
   oracle output files.

        ./bin/mgmt output blackscholes

3. Optimize blackscholes to reduce runtime energy consumption.

        ./bin/optimize benchmarks/blackscholes/src/blackscholes.s \
          blackscholes -l g++ -f -lpthread -e 256 -p 128 -P 64 -t 2

   The options specify that `g++` should be used as the linker, that
   the `-lpthread` should be passed to `g++` during linking, 256 total
   fitness evaluations should be run, a population of size 128 should
   be used, periodic checkpoints should be written every 64 fitness
   evaluations, and 2 threads should be used.

Interactive Optimization at the REPL
------------------------------------

See `src/repl/example.lisp`, which demonstrates how these tools may be
run interactively from the common lisp REPL.  The evolving population,
and many important evolutionary parameters are exposed as global
variables for live analysis and modification during interactive runs.

Experimental Reproduction
=========================

The following steps perform the optimizations of the PARSEC benchmark
applications for reduced energy consumption.

1. Check out the `main-experiment` tag of this repository and checkout
   commit `8193d14f` of the software-evolution repository.  Then
   re-build the executables with `make clean && make`.

2. Run the `self-test` script to ensure that the benchmark
   applications are available and can be successfully built and
   evaluated.  After some minutes (should be less than an hour, much
   less if much PARSEC has already been built) you should see a table
   of results printed.  If the table is all ✓'s and 0's then move on,
   otherwise you'll need to debug here, or skip any benchmark programs
   with ×'s or positive numbers in their row.

3. The system on which optimization runs will be performed should
   match the target environment.  For these runs we need to ensure the
   system is below full load and we do not use NFS or other data
   stores which may become easily overloaded.

4. An energy model should be trained for your system, the process of
   training an energy model is not covered here [10].  In our case the
   models included in `src/optimize.lisp` are used
   (`amd-opteron-power-model` and `intel-sandybridge-power-model` for
   our AMD and Intel systems respectively).

5. The `self-test` script should have populated all of the required
   assembler, test input and oracle output files needed by the
   optimization runs.

   The only other requirements are the `bin/limit` script which should
   have been built by running `make` above, and the `foreman` script
   running in the `sh-runner` directory (also described above).  Run
   the foreman script with a 30 second timeout as below from the
   sh-runner directory.

        ./foreman 30

   Each benchmark requires that the linker and flags be specified
   (`-l` and `-f` options to the `optimize` executable).  The values
   of these flags are stored in `etc/optimize-args`.

        # linker for swaptions
        grep swaptions etc/optimize-args|cut -f2

        # flags for swaptions
        grep swaptions etc/optimize-args|cut -f3

   Aside from these flags, all benchmarks will use the same arguments
   to `optimize`.  The correct GP parameters for these runs are
   already set as defaults in `optimize`.  The only other flags which
   should be used are given below.

        -w # path to the sh-runner working directory
        -t # number of threads to be used
        -r # path to the results directory

   Note that *only* these five flags to `optimize` (namely, `-l`,
   `-f`, `-w`, `-r`, `-t`) should be used in the main experimental
   runs.

Footnotes
=========

[1]  http://arxiv.org/abs/1204.4224

[2]  http://groups.csail.mit.edu/carbon/?page_id=111

[3]  https://perf.wiki.kernel.org/index.php/Main_Page

[4]  http://parsec.cs.princeton.edu/

[5]  http://www.spec.org/cpu2006/

[6]  http://www.sbcl.org/

[7]  http://ccl.clozure.com/

[8]  http://www.quicklisp.org/beta/

[9]  http://www.cliki.net/cl-launch

[10] See NOTES for pointers to methodology and shell scripts for
     training an energy model.  A WattsUp?™ Pro is required to measure
     wall plug energy consumption.  https://www.wattsupmeters.com