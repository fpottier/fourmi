(lang dune 3.22)
(name fourmi)
(generate_opam_files true)
(package
  (name fourmi)
  (authors
    "François Pottier <francois.pottier@inria.fr>"
  )
  (maintainers
    "François Pottier <francois.pottier@inria.fr>"
  )
  (source (uri git+https://github.com/fpottier/fourmi.git))
  (homepage https://github.com/fpottier/fourmi/)
  (bug_reports https://github.com/fpottier/fourmi/-/issues)
  (synopsis "A cooperative speculative computation library")
  (license "LGPL-2.0-only WITH OCaml-LGPL-linking-exception")
  (depends
    (ocaml (>= 5.5))
    (fix (and :with-test (>= 20261126)))
  )
)
