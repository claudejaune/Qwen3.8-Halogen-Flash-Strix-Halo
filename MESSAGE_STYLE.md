# Message style

This guide is for anyone writing text the user sees in the terminal: setup,
run, refresh, stop, and the shared helpers. That includes messages, prompts,
and error text.

The reader is new to local inference. They know a terminal, what `sudo` is, and
what local inference is. Write for them, not for the code.

Where this guide is silent, follow the Microsoft Style Guide. If you are unsure
about a word or a rule, ask the user. Do not guess.

## The rules

### 1. Say what the script does

Lead with the action or the result. Leave out what the script did not do, unless
the user will ask about it after a failure.

- Bad: `config.env was NOT written — nothing has changed.`
- Good: `Setup interrupted (Ctrl-C). Nothing was saved. Run ./setup.sh to finish.`

### 2. Use active voice

Put the actor first.

- Bad: `The weights download did not finish.`
- Good: `Download didn't finish. Run ./refresh.sh again to resume.`

### 3. Use one line when one line works

Use two lines only when the second line is a command the user copies.

- Bad: a three-line warning about bootloader changes.
- Good: `This edits your boot loader. A mistake can stop the machine from booting.`

### 4. Keep sentences short

Two sentences at most. Cut run-ons and parenthetical explanations.

- Bad: `The engine cannot start without GPU access. The usual cause is group membership; AMD's documented fix adds both groups (the -a keeps your existing ones):`
- Good: `Usually fixed by adding you to the render and video groups:`

### 5. Name the command

Any message that tells the user to act names the exact command: `./setup.sh`,
`./run.sh`, `./refresh.sh`, or `./stop.sh`. Do not write "Setup", "the script",
or "re-run" on their own.

- Bad: `Re-run setup after installing it.`
- Good: `Run ./setup.sh again.`

### 6. Show the commands the user will run

Keep `sudo` commands and the install line, for example
`Will run: sudo dnf install -y podman tuned`. Do not hide a command to make a
message shorter.

### 7. Use the names we settled on

| Use | For | Do not use |
|---|---|---|
| Halogen Flash | the server program | Halogen, halogen-flash-server, engine |
| Halogen Server | the API key prompt wording (approved) | |
| model | the Qwen model files | weights, checkpoint, quant |
| vision file | the vision download | sidecar |
| chats at once | the slots setting | slots, concurrency |
| version, with its owner | `Halogen Flash v0.17.4`, `the new model (v2)` | a bare `v2` or `v0.11.5` |

Also avoid these in user text: engine, image, container, sha256, hash, pinned,
recorded, verified, and `hf download` (except in a command the user copies).

Note: "Halogen" on its own is a different product, for a different model. Never
use it alone.

### 8. State a destructive step in full

Any step that stops a program, deletes files, or changes settings needs three
things:

1. What it stops or deletes. Name the files when the list is short.
2. What the user cannot do until it finishes.
3. The default answer. Use `[y/N]` for a deletion.

- Good:

  ```
  A newer model is available. Updating stops Halogen Flash and deletes the current model:
    <file>
  Halogen Flash can't run until the new model (~110 GiB) finishes downloading.
  Update now? [y/N]
  ```

### 9. End on what the user does next

Finish with a command or a clear state. The user should always know the next step.

- Good: `Setup complete. The model is not downloaded.` followed by
  `Run ./run.sh to download the model (~110 GiB).`

### 10. Reassure only when it answers a worry

A reassurance such as "Nothing was changed" helps after a failure. Do not add it
to routine messages.

### 11. Give the number and what it counts

Name the thing a number belongs to. Do not show hashes, URLs, or byte counts for
internal files. Show sizes the user needs to plan for, such as `~110 GiB` for a
model download.

### 12. Make errors specific

Say what is wrong and what to do, in one line.

- Bad: `Error: $var must be a number, got '$val' in config.env.`
- Good: `Invalid setting: PORT. Run ./setup.sh to fix it.`

## Before you commit a message

- Does it say what the script does?
- Is it active, short, and free of run-ons?
- Does every step that tells the user to act name the command?
- Does it avoid the terms in rule 7?
- Does every destructive step follow rule 8?
- Does it end on what the user does next?
