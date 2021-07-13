For finding in Erlang code using find instead of tags in Emacs.

EJump provides an xref-based interface for jumping to Erlang
definitions and call sites. It uses tools such as grep, the
silver searcher (https://geoff.greer.fm/ag/), ripgrep
(https://github.com/BurntSushi/ripgrep) or git-grep
(https://git-scm.com/docs/git-grep).

It is based on https://github.com/jacktasia/dumb-jump
but adapted for Erlang.

How to install and use it:

1. Install silversearcher-ag or ripgrep. Make sure you have git 2.13 or
   later.

2. To enable EJump, and prefer it over erlang-mode's tags lookup,
   add the following to your initialisation file:

```el
         (add-hook 'erlang-mode-hook 'my-set-xref-backend)
         (defun my-set-xref-backend ()
           (setq xref-backend-functions '(#'ejump-xref-activate)))
```
3. In a `.erl` file, move the cursor to a function call or a `?MACRO`
   use and type `M-.` to jump to the definition. On a function
   definition, Type `M-?` to search for calls to that function.

Things to improve:

- Lots, most likely :)
- Consider function and macro arity when searching, if possible
- Consider include file order when searching macros, if possible

Dependencies (available via [elpa](https://elpa.gnu.org/) or
[melpa](https://melpa.org/)):

* [popup](https://github.com/auto-complete/popup-el)
* [dash](https://github.com/magnars/dash.el)
* [s](https://github.com/magnars/s.el)
* [erlang](https://melpa.org/#/erlang) see also [erlang/otp on github](https://github.com/erlang/otp/tree/master/lib/tools/emacs)

Use for example `M-x package-install <pkg>` to install them.  Refer to
[melpa getting started](https://melpa.org/#/getting-started) for
info on how to set up your Emacs to access packages from melpa.
