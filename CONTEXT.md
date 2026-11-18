# Agentic Developer Platform

A platform that hosts agents built by other teams and governs every model call they make.

## Language

**Agent**:
A deployed workload with its own identity that contains a model and performs attempts when the controller asks; it can read business data but never change it.
_Avoid_: Bot, assistant, app

**Graph**:
The reasoning behind one attempt, written in LangGraph; it reads and proposes but changes nothing.
_Avoid_: Chain, pipeline, flow

**Attempt**:
One execution of a graph and the unit of durability: a finished attempt is recorded and never repeated, an interrupted one starts over.
_Avoid_: Try, iteration, step

**Run**:
The handling of one discrepancy from detection to its final outcome, under a single identity, surviving restarts.
_Avoid_: Thread, session, job

**Outcome**:
The way a run ends: committed, rejected, resolved elsewhere, unattended, or recommendation delivered. Passing a deadline is never an outcome that permits a change.
_Avoid_: Status, result, state

**Discrepancy**:
A state of business data that breaks a rule written down in advance, found without any model involved.
_Avoid_: Anomaly, error, issue

**Detection rule**:
The standing definition of one type of discrepancy, evaluated continuously against the data.
_Avoid_: Check, alert, detection query

**Fix type**:
A named, parameterised change that a detection rule declares in advance as an acceptable way to resolve its discrepancies.
_Avoid_: Remediation, action, template

**Proposed fix**:
A fix type plus parameters and supporting evidence, chosen by the model to resolve one discrepancy; it has no effect until granted.
_Avoid_: Patch, correction, SQL fix

**Recommendation**:
Written advice from the model for a discrepancy that no fix type fits; it goes to a human and can never be executed.
_Avoid_: Suggestion, free-form fix

**Approver**:
A named human who decides whether one exact proposed fix may take effect.
_Avoid_: Reviewer, admin, operator

**Grant**:
The record of an approver's decision, limited to one exact proposed fix; it is what the executor checks before acting.
_Avoid_: Approval flag, permission, token

**Controller**:
The workload that carries each run from start to outcome; it contains no model and can neither read nor change business data.
_Avoid_: Orchestrator, coordinator, manager

**Executor**:
The workload that applies a granted fix; it has its own identity, holds the only write access, and contains no model.
_Avoid_: Committer, writer, worker

**Model alias**:
The name an agent asks for (`fast`, `smart`), which the gateway resolves to a concrete model.
_Avoid_: Model name, route, tier

**Concrete model**:
One specific model at one provider, never addressed directly by an agent.
_Avoid_: Backend, upstream
