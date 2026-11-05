# ADR-0001: Start Elzoo as a fresh Mix application

*Status:* accepted for bootstrap

*Date:* 2026-11-05

## Context

The old Zoo repository contains a large Bend-specific catalogue, custom task
engine, generated surfaces and development gates. Elzoo wants the same useful
composition seam on Cure and OTP, but it is a new project with one Mix
application and a small working assembly.

## Decision

Start Elzoo from a clean Mix application. Carry forward only the vocabulary
and the operator/unit/port/edge/assembly boundary. Rebuild the catalogue as a
curated, dispositioned plan. Use Git, GitHub issues and Mix commands rather
than porting Zoo's task CLI, proof-everything lifecycle, generated manifest or
assurance badge system.

## Consequences

The bootstrap has less migration debt and can use OTP directly. Historical Zoo
names are aliases/research inputs, not implementation obligations. Claims must
be re-established in Elzoo's own tests and documents; the old repository is
not a transitive dependency. A capability enters only through a working
assembly and an explicit task.
