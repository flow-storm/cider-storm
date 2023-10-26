# Cider Storm

Cider Storm is an Emacs Cider front-end for the [FlowStorm debugger](https://github.com/flow-storm/flow-storm-debugger) with support for Clojure and ClojureScript.

It brings the time-travel code stepping capabilities of FlowStorm to Emacs, providing an interface 
similar to the Cider debugger one.

It also contains a bunch of utilities functions for interacting with FlowStorm.

Cider Storm isn't trying to re-implement the entire FlowStorm UI, but the most used functionality.
You can always start the full FlowStorm UI if you need the extra tools.


https://github.com/flow-storm/cider-storm/assets/786299/4328309c-9a60-47e1-ae1b-878884f19aa3


## Pre-requisites

- cider
- flow-storm >= `3.6.7`
- when using ClojureStorm >= `1.11.1-7` or >= `1.12.0-alpha4_1`
	
## Installation

First you need to setup FlowStorm as you normally do for your environment. Check https://flow-storm.github.io/flow-storm-debugger/user_guide.html#_quick_start

Apart from that you need two things. First clone this repo (no package yet) and load it into emacs, like :

```
(add-to-list 'load-path "/home/user/cider-storm")
(require 'cider-storm)
```

Second is to add the flow-storm nrepl middleware to your list of middlewares automatically loaded by your cider-jack-in commands.

There are multiple ways of accomplishing this depending on your use case, like : 

```
(add-to-list 'cider-jack-in-nrepl-middlewares "flow-storm.nrepl.middleware/wrap-flow-storm")
```

then the middleware will be added every time you do a cider-jack-in. The problem with this approach is that
if you jack-in into a project that doesn't contain FlowStorm on the classpath it will fail.

Another approach is to setup the middlewares like this in your `.dir-locals.el` at the root of each project.

```
((clojure-mode . ((cider-jack-in-nrepl-middlewares . ("flow-storm.nrepl.middleware/wrap-flow-storm"
													  ("refactor-nrepl.middleware/wrap-refactor" :predicate cljr--inject-middleware-p)
													  "cider.nrepl/cider-middleware")))))
```

There are other ways probably depending on what you are using and how you are starting your nrepl servers, but the important thing
is that the middleware should be loaded in the nrepl server for Cider Storm to work.

### Setup bindings

If you want to add bindings to your Cider map, you can also add :

```
(define-key cider-mode-map (kbd "C-c C-f") 'cider-storm-map)
```

which will add all the commands below under `C-c C-f`.

## List of commands cider-storm provides (assumes C-c C-f prefix)

|Command name                         |Binding|Description                                                                                        |
|-------------------------------------|-------|---------------------------------------------------------------------------------------------------|
|cider-storm-storm-start-gui          | s     | Starts the FlowStrom GUI                                                                          |
|cider-storm-storm-stop-gui           | x     | Stops the FlowStrom GUI                                                                           |
|cider-storm-instrument-current-ns    | n     | Instrument the current NS (vanilla only)                                                          |
|cider-storm-instrument-last-form     | f     | Instrument the form before the cursor (vanilla only)                                              |
|cider-storm-instrument-current-defn  | c     | Instrument the form surrounding the cursor (vanilla only)                                         |
|cider-storm-eval-and-debug-last-form | e     | Eval and debug last form (will use #rtrace on vanilla)                                            |
|cider-storm-tap-last-result          | t     | Taps the last evaluated expression (*1)                                                           |
|cider-storm-show-current-var-doc     | D     | Shows the FlowStorm doc for the current var                                                       |
|cider-storm-rtrace-last-sexp         | r     | #rtrace the last s-expression                                                                     |
|cider-storm-debug-current-fn         | d     | Moves the stepper to the first recording for the current fn (cursor needs to be on the fn symbol) |
|cider-storm-debug-fn                 | j     | Select a recorded fn and make the stepper jump into it                                            |
|cider-storm-clear-recordings         | l     | Clear all recordings (same as Ctrl-L on the FlowStorm UI)                                         |

## Stepper Usage

### With ClojureStorm (recommended for Clojure)

If you are using FlowStorm with ClojureStorm, then you don't need to do anything special, you don't even need the FlowStorm UI running.

Start your repl, run your expressions so things get recorded and then when you want to step over a recorded function on emacs
run : M-x cider-storm-debug-fn

This should retrieve a list of all the functions that FlowStorm has recordings for. When you choose one, it should jump to the first 
recorded step for that function, and provide a similar interface to the Cider debugger.

Once the debugging mode is enable you can type `h` to show the keybindings.

### With vanilla FlowStorm

Currently you need to have the FlowStorm UI running (flow-storm.api/local-connect) to use it with vanilla FlowStorm.

After you have your recordings you can explore them following the same instructions described in `With ClojureStorm` .

### With ClojureScript

You need to make sure you have the middleware `flow-storm.nrepl.middleware/wrap-flow-storm` injected on your repl nrepl server.

For example, if you are using it with shadow-cljs you will have to add the middleware to your shadow-cljs nrepl server config like this :

```clojure
{...
 :nrepl {:port 7123
         :middleware [flow-storm.nrepl.middleware/wrap-flow-storm]}
 :builds {:my-app {...}}}
```

Having done that, you can then `cider-jack-in-cljs` > `shadow` > `:my-app` which should start shadow and give you a cljs repl.

Once you are sure you can eval expressions from your buffers, then try `cider-storm-debug-fn` which should let you choose between
all recorded functions in the same way as FlowStorm UI `Quick jump`

Currently we need to have the FlowStorm debugger UI connected to use it with ClojureScript.

After you have your recordings you can explore them following the same instructions described in `With ClojureStorm`.

## Tips

### Clear recordings

Same as when using the FlowStorm UI, it is convenient to clear the recordings frequently so you don't get confused with previous recordings.
You can do this from emacs by M-x cider-storm-clear-recordings

### Value inspection

By hitting `i` Cider Storm will inspect the value using the Cider inspector. If you want to inspect values using other inspectors (like the FlowStorm one)
you can hit `t` to tap the value.


