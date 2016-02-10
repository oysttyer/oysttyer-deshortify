# oysttyer-deshortify
Never again see a shortened URL in your `oysttyer` stream


## What?

This `oysttyer` extension resolves "shortened" URLs by following every link until there is no redirection, so you see the final URL. Here is an example of how deshortifier works (you can see this, too, by running `oysttyer -verbose=1`):

```
-- calling $handle in deshortify.pl
-- Deshortened: http://di.gg/1Xp1Sx6 -> http://trib.al/dP0a5Aj
-- Deshortened: http://trib.al/dP0a5Aj -> https://www.inverse.com/article/8474-people-are-going-to-have-a-lot-of-sex-in-driverless-cars?utm_source=digg&utm_medium=twitter
a1> {,669255082970587136} [2015-11-24 21:43:40] (x9) <↑digg> People are going to have so much sex
in driverless cars: https://www.inverse.com/article/8474-people-are-going-to-have-a-lot-of-sex-in-driverless-cars?
```

Compare that to the un-deshortified version which points you to a mistery webpage:

```
a1> {,669255082970587136} [2015-11-24 21:43:40] (x9) <↑digg> People are going to have so much sex
in driverless cars: http://di.gg/1Xp1Sx6
```

It will also underline URLs if your terminal supports ANSI.

Deshortify also does some tricks to URLs to make them shorter and readable-er: resolves feedburner and google news URLs, and cuts off some extraneous tracking stuff from the end of URLs (those "utm_source=twitter" bits that don't do anything useful to you and just take up space), and properly follows some `<iframe>`-based shorteners.

Under the hood, deshortify uses HTTP HEAD requests to resolve most URL shorteners (except the iframe-based ones), and this takes time. It is normal for your tweets to lag a second or two before being displayed. Also, any URLs resolved may count as visited for some SEO tracking platforms, even though the requests are made with a bot-like user-agent - privacy junkies be warned.


## Usage

After downloading, enable the extension in your `.oysttyerrc` file:

```
exts=path/to/deshortify.pl
```

If you use more than one extension:

```
exts=path/to/deshortify.pl,path/to/another-extension.pl
```

The following extra options are available:


* `extpref_deshortifyproxy=http://proxy.localnetwork:8001/`: Overrides system proxy settings. Deshortify tries to use the proxy defined in your environment variables but, if that fails for whatever reason, you can specify it in here.

* `extpref_deshortifyretries=10`: It is possible that resolving a shortener will timeout or fail for whatever reason. When this happens, deshortify will retry up to 3 times unless you modify this setting.

* `extpref_deshortifyalways=1`: By default, deshortify only works on a list of known URL shorteners. This means "shorteners that [Iván](http://twitter.com/RealIvanSanchez) has seen in his timeline". Setting this will cause deshortify to *always* follow a link, regardless of if the URL seems to come from a shortener. Be warned: this means one more HTTP request per URL, which means more lagginess.


`deshortify` needs `libwww-perl` and `liburi-find-perl`. You can install them by running `cpan URI::Find`, `cpan URI::Split` and `cpan LWP::UserAgent`. You may need to use `sudo cpan <module>` when installing cpan modules, depending on the setup of your local system.

Some systems have SSL verification turned on but don't ship with the necessary CA cerificates for this to work.  If that's the case, you will also need to install the CA certificates by running `cpan Mozilla::CA`. You'll know if you're affected by this issue because you'll see errors such as the following when someone tweets an HTTPS URL:

    *** Could not deshortify https://example.com/something further due to 500 Can't verify SSL peers without knowing which Certificate Authorities to trust





## Legalese

---

  "THE BEER-WARE LICENSE":
<ivan@sanchezortega.es> wrote this file. As long as you retain this notice you
can do whatever you want with this stuff. If we meet some day, and you think
this stuff is worth it, you can buy me a beer in return.

---
