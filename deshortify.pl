
#  ----------------------------------------------------------------------------
#  "THE BEER-WARE LICENSE":
#  <ivan@sanchezortega.es> wrote this file. As long as you retain this notice you
#  can do whatever you want with this stuff. If we meet some day, and you think
#  this stuff is worth it, you can buy me a beer in return.
#  ----------------------------------------------------------------------------
#
# De-shortification of URLs in tweets.
#
# This extension will go through each of the received tweets and try to unshorten 'em all. Not all urls shorteners and redirects are known, so some URLs will not be the final ones.
#
# Requirements: URI::Find and URI::Split and LWP::UserAgent. Please run "apt-get install liburi-find-perl libwww-perl" or "cpan URI::Find" and "cpan URI::Split" and "cpan LWP::UserAgent" if this extension fails to load.
#
# Features:
#  * A non-comprehensive list of known URL shorteners
#  * Fancy ANSI underlining of URLs that will break if the URL contains a search term
#  * Lightweight, HEAD-only requests.
#  * Fancy custom user agent (Unlike main TTYtter), friendlier to website sysadmins.
#  * De-shortened URLs cache, in order to not request anything when you see the same URL time and time again (useful for mass RTs or TTs)
#  * The de-shortened URLs cache will empty from time to time (currently every 2000 URLs) in order to prevent taking up too much memory.
#  * Web stats tracking queries de-crapifier. No more useless ?utm_medium=twitter littering your stream. And a tiny bit of better privacy for you.
#  * Replaces URL-encoded UTF-8 in the URL body for the corresponding character (i.e. "%C4%99" turns into "ę"). Hopefully this won't mess up non-UTF-8 systems.
#  * Proxy support. Deshortify will try to fetch proxy config from environment variables. Tor users will be interested in adding the following to their .ttytterrc file:
#       extpref_deshortifyproxy=socks://localhost:9050
#  * Proper support for relative URLs
#
# Bugs and gotchas:
#  * Might fail to resolve a URL you just posted in stream mode: the t.co shortener needs a couple of seconds after the tweet was posted in order to be able to resolve the URLs.
#  * Might fail to maintain the integrity of a URL with lots of URL-encoded = and & and / and spaces whatnot. Apply the trick commented in the code and report back to me, will you?
#  * Proxy configuration is deshortify-specific. Deshortify uses perl's LWP::UserAgent instead of lynx or curl. If you use a proxy, you'll have to configure ttytter and deshortify separately.
#  * Verbose mode is verbose. Very.
#
# Be advised: this extension will send HTTP HEAD requests to all the URLs to be resolved. Be warned of this if you're concerned about privacy.
#
# TODO: Allow a screen width to be specified, and then don't de-shortify links if the width of the tweet would exceed that. Or get the screen width from the environment somehow.
# TODO: Add a carriage return (but no line feed) ANSI control char, after the links have been deshortified. If you're writing something while URLs are being resolved, the display will be messed up. Hopefully a CR will help hide the problem. Update: ANSI control chars to move the cursor or clear the current line will fail miserably; all I managed is to add a blank line between tweets. It seems that it has something to do with ReadLine::TTYtter.
# TODO: Fix TTYtter so that search and tracked keywords are shown with the "Bold on" and "bold off" ANSI sequences instead of "bold on" and "reset". Right now URL underlining will be messed up if the full URL contains the keyword. Hopefully this can be done in 2.1.0 or 2.2.0.
# TODO: Prevent shortener infinite loops via a mechanism similar to deshortify_retries, max depth being configurable via parameters
# TODO: Prevent shortener infinite loops via detection of loops in the cache.



# Show when extension is being loaded
print "-- Don't like to see short URLs, do you?\n";


# If a proxy is set due to environment variables or .ttytterrc, tell so during load. Not really needed, but for as long as I cannot test it, this might be useful.
if ($extpref_deshortifyproxy)
{
	print "-- Deshortify will use $extpref_deshortifyproxy as a proxy for both HTTP and HTTPS requests\n";
}
elsif ( $ENV{http_proxy} or $ENV{https_proxy} )
{
	if ( $ENV{http_proxy} ){
		print "-- Deshortify will use $ENV{http_proxy} as a proxy for HTTP requests\n";
	} else {
		print "-- Deshortify will not use a proxy for HTTP requests\n";
	}

	if ( $ENV{https_proxy} ){
		print "-- Deshortify will use $ENV{https_proxy} as a proxy for HTTPS requests\n";
	} else {
		print "-- Deshortify will not use a proxy for HTTPS requests\n";
	}
}

if (not $extpref_deshortifyretries)
{
    $extpref_deshortifyretries = 3;
}

if (not $extpref_deshortifyloopdetect)
{
    $extpref_deshortifyloopdetect = 20;
}

require URI::Find;

use URI::Split qw(uri_split uri_join);

use LWP::UserAgent;

use Data::Dumper qw{Dumper};



# Define UNDEROFF, to turn off just the underlining
$ESC = pack("C", 27);
$UNDEROFF = ($ansi) ? "${ESC}[24m" : '';


our %deshortify_cache = ();

# our $deshortify_cache_empty_counter = 0;
# our $deshortify_cache_limit = 2000;
# our $deshortify_cache_flushes = 0;
# our $deshortify_cache_hit_count = 0;

our %store = ( "cache_misses", 0, "cache_limit", 2000, "cache_flushes", 0, "cache_hit_count", 0);


# For some strange reason initial values up there are ignored. FIXME: Why?
$store->{cache_limit} = 2000;
$store->{cache_misses} = 0;
$store->{cache_hit_count} = 0;
$store->{cache_flushes} = 0;











# Quick sub to retry unshorting of URLs
# Called when a HTTP operation failed for any reason; the algorithm will retry a few times (as specified in $extpref_deshortifyretries) before failing.
$unshort_retry = sub{

	my $url = shift;
	my $retries_left = shift;
	my $reason = shift;

	if ($retries_left eq 0)
	{
		&$exception(32, "*** Could not deshortify $url further due to $reason\n");
		return &$cleanup_url($url);
	}
	else
	{
		print $stdout "-- Deshortify failed for $url due to $reason, retrying ($retries_left retries left)\n" if ($verbose);
		return &$unshort($url, $retries_left-1, $extpref_deshortifyloopdetect);
	}
	return 0;
};



# Cleans up a URL, stripping off garbage after the URL's hash. Also, prettify URL with underlining.
# This won't affect useability of the URL.
$cleanup_url = sub{

    my $url = shift;

    ($scheme, $auth, $path, $query, $frag) = uri_split($url);


    # Do some heuristics and try to stave off stupid, spurious crap out of URLs. Like "?utm_source=twitterfeed&utm_medium=twitter
    # This crap is used for advertisers to track link visits. Screw that!

    # Stuff to cut out: utm_source utm_medium utm_term utm_content utm_campaign (from google's ad campaigns)
    # Stuff to cut out: spref=tw (from blogger)
    # Stuff to cut out: ref=tw (from huff post and others)
    # Stuff to cut out: feature=whatever when on youtube.com

#       print "-- scheme $scheme auth $auth path $path query $query frag $frag\n" if ($verbose);
    if ($query)
    {
        @pairs = split(/&/, $query);
        foreach $pair (@pairs){
            ($name, $value) = split(/=/, $pair);

            if ($name =~ m#_source$# or $name =~ m#_medium$# or $name =~ m#_term$# or $name =~ m#_content$# or $name =~ m#_campaign$# or $name =~ m#_mchannel$# or $name =~ m#_kwd$#
                or ( $name eq "utm_cid")
                or ( $name eq "cm_mmc")
                or ( $name eq "tag" and $value eq "as.rss" )
                or ( $name eq "ref" and $value eq "rss" )
                or ( $name eq "ref" and $value eq "tw" )
                or ( $name eq "id_externo_rsoc" and $value eq "TW_CM" )
                or ( $name eq "newsfeed" and $value eq "true" )
                or ( $name eq "spref" and $value eq "tw" )
                or ( $name eq "spref" and $value eq "fb" )
                or ( $name eq "spref" and $value eq "gr" )
                or ( $name eq "source" and $value eq "twitter" )
                or ( $name eq "platform" and $value eq "hootsuite" )
                or ( $name eq "mbid" and $value eq "social_retweet" )   # New Yorker et al
                or ( $name eq "mbid" and $value eq "social_twitter" )   # New Yorker et al
                or ( $auth eq "www.youtube.com" and $name eq "feature")
                or ( $auth eq "www.nytimes.com" and $name eq "smid" )   # New York Times
                or ( $auth eq "www.nytimes.com" and $name eq "seid" )   # New York Times
                or ( $name eq "awesm" ) # Appears as a logger of awesm shortener, at least in storify
                or ( $name eq "CMP"  and $value eq "twt_gu")    # Guardian.co.uk short links
                or ( $name eq "ex_cid" and $value eq "story-twitter")
                or ( $name eq "ocid" and $value eq "socialflow_twitter")
                or ( $name eq "ocid" and $value eq "socialflow_facebook")
                or ( $name =~ m#_src$# and $value eq "social-sh")
                or ( $name eq "soc_trk" and $value eq "tw")
                or ( $name eq "a" and $value eq "socialmedia")	# In meetup.com links
                    )
            {
                my $expr = quotemeta("$name=$value");   # This prevents strings with "+" to be interpreted as part of the regexp
                $query =~ s/($expr)&//;
                $query =~ s/&($expr)//;
                $query =~ s/($expr)//;
                print $stdout "---- Trimming spammy URL parameters: $name = $value - now $query\n" if ($superverbose);
            }
        }
        $url = uri_join($scheme, $auth, $path, $query, $frag);
    }

    if ($frag)
    {
		if ($auth eq "medium.com" or
		    $auth eq "mashable.com" or
		    $auth eq "www.larazon.es" or
		    $frag =~ m#^\.#	# If the fragment starts with a dot then it's a JS tracker
		    )
		{
			$frag = "";
			
			$url = uri_join($scheme, $auth, $path, $query, $frag);
		}
		
    }
    
    if ($path)
    {
		if ($auth eq "news.yahoo.com")
		{
			$path =~ s/;.*$//;	# Strip everything from the first ';' onwards.
			
			$url = uri_join($scheme, $auth, $path, $query, $frag);
		}
		
    }    
    
    
#       # Dirty trick to prevent escaped = and & and # to be unescaped (and mess up the query string part) - escape them again!
#       $url =~ s/%24/%2524/i;  # $
#       $url =~ s/%26/%2526/i;  # &
#       $url =~ s/%2B/%252B/i;  # +
#       $url =~ s/%2C/%252C/i;  # ,
#       $url =~ s/%2F/%252F/i;  # /
#       $url =~ s/%3A/%253A/i;  # :
#       $url =~ s/%3B/%253B/i;  # ;
#       $url =~ s/%3D/%252B/i;  # =
#       $url =~ s/%3F/%252B/i;  # ?
#       $url =~ s/%40/%252B/i;  # @

    # Replace %XX for the corresponding character - makes URLs more compact and legible. Hopefully won't mess anything up.
    $url =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
    # Waaaait a second, did we just replace "%20" for " "? That'll just mess up things...
#     $url =~ s/ /+/g;
    $url =~ s/ /%20/g;

    return ${UNDER} . $url . ${UNDEROFF};
};






# Given a URL, will unshort it.
$unshort = sub{
	our $verbose;
	our $superverbose;
	our $oysttyer_VERSION;
# 	our $deshortify_cache;
	our $store;
	my $url = shift;
    my $retries_left = shift;
    my $loop_detect = shift;

	my $original_url = $url;

	# parse and break the url into components
	($scheme, $auth, $path, $query, $frag) = uri_split($url);

# 	print "scheme $scheme auth $auth path $path query $query frag $frag\n" if ($verbose);

	my $unshorting_method = none;
	my $unshorting_regexp;
	my $unshorting_override = 0;

	# Over time, I've gathered a few shorteners and common patterns for URL shorteners.
	# Should not be considered as a comprehensive list, but it'll do.
	
	if ($auth eq "po.st" or
	       $auth eq "Iad.bg" or
	       $auth eq "iad.bg" or
	       $auth eq "Nvda.ly" or	# Nvidia
	       $auth eq "nvda.ly" or
	       $auth eq "mwcb.in" or	# Mobile World Capital
	       $auth eq "social.os.uk")
	{
		# For these servers, perform a HTTP GET request, hope for a 30* header back. Use for shorteners that fail with HEAD requests.
		# This check is done before the normal shorteners, as these might share some matching regexp
		$unshorting_method = "GET";	
	}
	elsif (($path =~ m#^/p/#)  or  # Generic short links
	    ($path =~ m#^/r/# )	or	# Some generic reddit-like shortener, I think.
	    ($path =~ m#^/go/#)	or	# OpenStreetMap-style
	    ($path =~ m#^/[A-Za-z0-9]{2,12}$#)	or	# Only letters and numbers (no slashes, no dots)? Most likely a bit.ly-like shortener.
	    ($path =~ m#^/[A-Za-z0-9\-]{10,16}$#)	or	# wp.me-like shorteners also use dashes
	    ($path =~ m#^/[A-Za-z0-9\-_]{12,16}$#)	or	# Tumblr & co use a similar approach, but with dashes, lodashes and more characters.
	    ($query =~ m#utm_source=# )	or	# Any URL from *any* server which contains "utm_source=" looks like a social SEO marketing campaign-speech-enabled linkification
	    ($query =~ m#utm_medium=# )	or	# Any URL from *any* server which contains "utm_medium=" looks like a social SEO marketing campaign-speech-enabled linkification
	    ($query =~ m#url=http# )	or	# Any URL from *any* server which contains "url=http" looks like a redirector
	    ($query =~ m#redirect# )	or	# Any URL from *any* server which contains a "redirect*" parameter looks like a redirector
	    ($query =~ m#^p=\d+$# )	or	# Any URL from *any* server which contains "p=1234" looks like a wordpress
	    ($query =~ m#^\d+$# )	or	# Any URL from *any* server which is just numbers, high prob. it's a code for something else
	    ($query =~ m#glink\.php# )	or	# Any URL from *any* server which contains 'glink.php'
# 	    ($auth eq "g.co")	or	# Google
# 	    ($auth eq "j.mp")	or
# 	    ($auth eq "q.gs")	or
# 	    ($auth eq "n.pr")	or	# NPR, National Public Radio (USA)
# 	    ($auth eq "t.co")	or	# twitter
# 	    ($auth eq "v.gd")	or	# Ethical URL shortener by memset hosting
# 	    ($auth eq "bv.ms")	or	# Bloomberg
# 	    ($auth eq "cl.ly")	or
# 	    ($auth eq "db.tt")	or
# 	    ($auth eq "di.gg")	or
# 	    ($auth eq "ds.io")	or
# 	    ($auth eq "ed.lc")	or
# 	    ($auth eq "es.pn")	or
# 	    ($auth eq "fb.me")	or
# 	    ($auth eq "fw.to")	or
# 	    ($auth eq "ht.ly")	or
# 	    ($auth eq "if.lc")	or
# 	    ($auth eq "is.gd")	or
# 	    ($auth eq "kl.am")	or
# 	    ($auth eq "me.lt")	or
# 	    ($auth eq "mf.tt")	or
# 	    ($auth eq "om.ly")	or
# 	    ($auth eq "ow.ly")	or
# # 	    ($auth eq "po.st")	or	# Doesn't allow HTTP HEAD requests, doing GET requests.
# 	    ($auth eq "qr.ae")	or	# Quora
# 	    ($auth eq "su.pr")	or
# 	    ($auth eq "ti.me")	or
# 	    ($auth eq "tl.gd")	or	# Twitlonger
# 	    ($auth eq "to.ly")	or
# 	    ($auth eq "tr.im")	or
# 	    ($auth eq "wj.la")	or	# ABC7 News (washington)
# 	    ($auth eq "wp.me")	or	# Wordpress
# 	    ($auth eq "29g.us")	or
# 	    ($auth eq "abr.ai")	or	# Abril.com.br, brazilian newspaper
# 	    ($auth eq "adf.ly")	or
# 	    ($auth eq "aka.ms")	or	# Microsoft's "Social eXperience Platform"
# 	    ($auth eq "api.pw")	or	# Programmable Web
# 	    ($auth eq "ara.tv")	or	# alarabiya.net
# 	    ($auth eq "ars.to")	or	# Ars Tecnica
# 	    ($auth eq "aol.it")	or	# AOL, America OnLine
# 	    ($auth eq "awe.sm")	or
# 	    ($auth eq "bbc.in")	or	# bbc.co.uk
	    ($auth eq "bit.ly")	or	# Bitly usually fits the "16 numbers and letters" regexp, but also has longer vanity URLs.
# 	    ($auth eq "bsa.sc")	or	# British Science Association
# 	    ($auth eq "cbc.sh")	or	# leads to cbc.ca. Congrats, four characters saved.
# 	    ($auth eq "cdb.io")	or
# 	    ($auth eq "cgd.to")	or
# 	    ($auth eq "chn.ge")	or	# Change.org
# 	    ($auth eq "cli.gs")	or
# 	    ($auth eq "clp.im")	or	# Powered by auto-tweet
# 	    ($auth eq "cor.to")	or
# 	    ($auth eq "cos.as")	or
# 	    ($auth eq "cot.ag")	or
# 	    ($auth eq "cnn.it")	or
# 	    ($auth eq "cur.lv")	or
# 	    ($auth eq "del.ly")	or	# Powered by Sprinklr
# 	    ($auth eq "dld.bz")	or
# 	    ($auth eq "ebx.sh")	or
# 	    ($auth eq "ebz.by")	or
# 	    ($auth eq "esp.tl")	or	# Powered by bitly
# 	    ($auth eq "fdl.me")	or
# 	    ($auth eq "fon.gs")	or	# Fon Get Simple (By the fon.com guys)
# 	    ($auth eq "for.tn")	or	# Fortune.com
# 	    ($auth eq "fro.gd")	or	# Frog Design
# 	    ($auth eq "fxn.ws")	or	# Fox News
# 	    ($auth eq "gaw.kr")	or	# Gawker
# 	    ($auth eq "git.io")	or	# GitHub
# 	    ($auth eq "gkl.st")	or	# GeekList
# 	    ($auth eq "glo.bo")	or	# Brazilian Globo
	    ($auth eq "goo.gl")	or	# Google
# 	    ($auth eq "gph.is")	or	# Giphy
# 	    ($auth eq "grn.bz")	or
# 	    ($auth eq "gtg.lu")	or	# GetGlue (TV shows)
# 	    ($auth eq "gu.com")	or	# The Guardian
# 	    ($auth eq "htl.li")	or
# 	    ($auth eq "htn.to")	or
# 	    ($auth eq "hub.am")	or
# 	    ($auth eq "ick.li")	or
# 	    ($auth eq "ift.tt")	or	# If This Then That
# 	    ($auth eq "ind.pn")	or	# The Independent.co.uk
# 	    ($auth eq "kck.st")	or	# Kickstarter
# 	    ($auth eq "kcy.me")	or	# Karmacracy
# 	    ($auth eq "kng.ht")	or	# Knight Foundation
# 	    ($auth eq "lat.ms")	or
# 	    ($auth eq "mbl.mx")	or
# 	    ($auth eq "mun.do")	or	# El Mundo
# 	    ($auth eq "muo.fm")	or	# MakeUseOf
# 	    ($auth eq "mzl.la")	or	# Mozilla
# 	    ($auth eq "ngr.nu")	or	# Powered by bit.ly
# 	    ($auth eq "nsm.me")	or
# 	    ($auth eq "nym.ag")	or	# New York Magazine
# 	    ($auth eq "nyr.kr")	or	# New Yorker
# 	    ($auth eq "ofa.bo")	or
# 	    ($auth eq "osf.to")	or	# Open Society Foundation
# 	    ($auth eq "ovh.to")	or	# OVH telecom
# 	    ($auth eq "owl.li")	or
# 	    ($auth eq "pco.lt")	or
# 	    ($auth eq "prn.to")	or	# PR News Wire
# 	    ($auth eq "r88.it")	or
# 	    ($auth eq "rdd.me")	or
# 	    ($auth eq "red.ht")	or
# 	    ($auth eq "reg.cx")	or
# 	    ($auth eq "rol.st")	or	# Rolling Stone magazine
# 	    ($auth eq "rlu.ru")	or
# 	    ($auth eq "rpx.me")	or	# http://janrain.com, social media company
# 	    ($auth eq "rsc.li")	or
# 	    ($auth eq "rww.to")	or
# 	    ($auth eq "si1.es")	or
# 	    ($auth eq "sbn.to")	or
# 	    ($auth eq "sco.lt")	or
# 	    ($auth eq "s.coop")	or	# Cooperative shortening
# 	    ($auth eq "see.sc")	or
# 	    ($auth eq "sfy.co")	or	# Storify
# 	    ($auth eq "shr.gs")	or
# 	    ($auth eq "smf.is")	or	# Summify
# 	    ($auth eq "sns.mx")	or	# SNS analytics
# 	    ($auth eq "soa.li")	or
# 	    ($auth eq "soc.li")	or
# 	    ($auth eq "spr.ly")	or	# Sprinklr
# 	    ($auth eq "sta.mn")	or	# Stamen - Gotta love these guys' maps!
# 	    ($auth eq "tgn.me")	or
# 	    ($auth eq "tgr.ph")	or	# The Telegraph
# 	    ($auth eq "tnw.co")	or	# TheNextWeb
# 	    ($auth eq "tnw.to")	or	# TheNextWeb
# 	    ($auth eq "tnw.me")	or	# TheNextWeb
# 	    ($auth eq "tny.cz")	or
# 	    ($auth eq "tny.gs")	or
# 	    ($auth eq "tpm.ly")	or
# 	    ($auth eq "tpt.to")	or
# 	    ($auth eq "ur1.ca")	or
# 	    ($auth eq "ver.ec")	or	# E-Cartelera (spanish tv&movies)
# 	    ($auth eq "vkm.is")	or	# Verkami
# 	    ($auth eq "vsb.li")	or
# 	    ($auth eq "vsb.ly")	or
# 	    ($auth eq "wef.ch")	or	# WeForum
# 	    ($auth eq "wrd.cm")	or	# Wired.com
# 	    ($auth eq "wh.gov")	or	# Whitehouse.gov
# 	    ($auth eq "wpo.st")	or	# Washington Post
# 	    ($auth eq "zd.net")	or
# 	    ($auth eq "zpr.io")	or
# 	    ($auth eq "1drv.ms")	or
# 	    ($auth eq "1776.ly")	or
# 	    ($auth eq "6sen.se")	or
# 	    ($auth eq "atfp.co")	or
# 	    ($auth eq "amba.to")	or	# Ameba.jp
# 	    ($auth eq "amzn.to")	or	# Amazon.com
# 	    ($auth eq "apne.ws")	or	# AP news
# 	    ($auth eq "arcg.is")	or	# ESRI's ArgCIS online
# 	    ($auth eq "bgcd.co")	or	# BugCrowd
# 	    ($auth eq "blgs.co")	or
# 	    ($auth eq "buff.ly")	or
# 	    ($auth eq "buzz.mw")	or
# 	    ($auth eq "bzfd.it")	or	# Buzzfeed
# 	    ($auth eq "cbsn.ws")	or	# CBS News
# 	    ($auth eq "chzb.gr")	or	# Cheezburguer network
# 	    ($auth eq "clic.bz")	or  # Powered by bit.ly
# 	    ($auth eq "cnet.co")	or	# C-Net
# 	    ($auth eq "cort.as")	or
# 	    ($auth eq "cutv.ws")	or	# cultureunplugged.com
# 	    ($auth eq "cyha.es")	or	# CyberHades.com
# 	    ($auth eq "dell.to")	or	# Dell
# 	    ($auth eq "dive.im")	or	# DiveMedia Solutions
# 	    ($auth eq "disq.us")	or
# 	    ($auth eq "dlvr.it")	or
# 	    ($auth eq "econ.st")	or	# The Economist
# 	    ($auth eq "engt.co")	or	# Engadget
# # 	    ($auth eq "flic.kr")	or	# Hhhmm, dunno is there's much use in de-shortening to flickr.com anyway.
# 	    ($auth eq "flip.it")	or	# Flipboard
# 	    ($auth eq "fork.ly")	or	# Forkly.com, although full URL doesn't add any useable info, much like foursquare
# 	    ($auth eq "geog.gr")	or	# Geographical.co.uk
# 	    ($auth eq "gen.cat")	or	# Generalitat Catalana (catalonian gov't)
# 	    ($auth eq "hint.fm")	or
# 	    ($auth eq "hubs.ly")	or
# 	    ($auth eq "hptx.al")	or	# Hypertextual
# 	    ($auth eq "huff.to")	or	# The Huffington Post
# 	    ($auth eq "imrn.me")	or
# 	    ($auth eq "itun.es")	or	# iTunes, shows long name of podcasts
# 	    ($auth eq "josh.re")	or
# 	    ($auth eq "jrnl.to")	or	# Powered by bit.ly
# 	    ($auth eq "klls.cr")	or	# KillScreen
# 	    ($auth eq "klou.tt")	or
# 	    ($auth eq "likr.es")	or	# Powered by TribApp
# 	    ($auth eq "lnkd.in")	or	# Linkedin
# 	    ($auth eq "mdia.st")	or	# Mediaset (spanish TV station)
# 	    ($auth eq "mirr.im")	or	# The Daily Mirror (UK newspaper)
# 	    ($auth eq "miud.in")	or	($auth eq "redirect.miud.in")	or
# 	    ($auth eq "mojo.ly")	or	# Mother Jones
# 	    ($auth eq "monk.ly")	or
# 	    ($auth eq "mrkt.ms")	or	# MarketMeSuite (SEO platform)
# 	    ($auth eq "msft.it")	or	# Microsoft
# 	    ($auth eq "nblo.gs")	or	# Networked Blogs
# 	    ($auth eq "neow.in")	or	# NeoWin
# 	    ($auth eq "note.io")	or
# 	    ($auth eq "noti.ca")	or
# 	    ($auth eq "nydn.us")	or	# New York Daily News
# 	    ($auth eq "nyer.cm")	or  # New Yorker
# 	    ($auth eq "nyti.ms")	or  # New York Times
# 	    ($auth eq "nzzl.me")	or
# 	    ($auth eq "onvb.co")	or	# Venture Beat
# 	    ($auth eq "pear.ly")	or
# 	    ($auth eq "post.ly")	or	# Posterous
# 	    ($auth eq "ppfr.it")	or
# 	    ($auth eq "prsm.tc")	or
# 	    ($auth eq "qkme.me")	or	# QuickMeme
# 	    ($auth eq "read.bi")	or	# Business Insider
# 	    ($auth eq "ride.sc")	or	# RideScout
# 	    ($auth eq "sbne.ws")	or	# SmartBrief News
# 	    ($auth eq "snpy.tv")	or	# Snappy TV
# 	    ($auth eq "stuf.in")	or	#
# 	    ($auth eq "redd.it")	or	($auth eq "www.reddit.com" and $path =~ m#^/tb/#)   or  # Reddit
# 	    ($auth eq "reut.rs")	or  # Reuters
# 	    ($auth eq "seen.li")	or	($auth eq "seenthis.net" and $path eq "/index.php")	or # SeenThis, AKA http://seenthis.net/index.php?action=seenli&me=1ing
# 	    ($auth eq "seod.co")	or
# 	    ($auth eq "shar.es")	or
# 	    ($auth eq "shrd.by")	or	# sharedby.co "Custom Engagement Bar and Analytics"
# 	    ($auth eq "slnm.us")	or	# Salon
# 	    ($auth eq "sml8.it")	or
# 	    ($auth eq "smrt.in")	or	# Powered by bit.ly
# 	    ($auth eq "snpy.tv")	or	# Snappy TV
# 	    ($auth eq "tcrn.ch")	or	# Techcrunch
# 	    ($auth eq "tiny.cc")	or
# 	    ($auth eq "tuxi.tk")	or
# 	    ($auth eq "trib.al")	or	($auth =~ m/\.trib\.al$/ )	or	# whatever.trib.al is done by SocialFlow
# 	    ($auth eq "untp.it")	or	# Untap, via Bitly
# 	    ($auth eq "usat.ly")	or	# USA Today
# 	    ($auth eq "ves.cat")	or
# 	    ($auth eq "vrge.co")	or	# The Verge
# 	    ($auth eq "wapo.st")	or	# Washington Post
# 	    ($auth eq "wrld.bg")	or	# World Bank Blogs
# 	    ($auth eq "xfru.it")	or
# 	    ($auth eq "xfru.it")	or	($auth eq "www.xfru.it")	or
# 	    ($auth eq "xure.eu")	or
# 	    ($auth eq "xurl.es")	or
# 	    ($auth eq "yhoo.it")	or	# Yahoo
# 	    ($auth eq "zite.to")	or
# 	    ($auth eq "53eig.ht")	or ($auth eq "fivethirtyeight.com")	or
# 	    ($auth eq "a.eoi.co")	or	# Escuela de Organización Industrial
# 	    ($auth eq "a.eoi.es")	or	# Escuela de Organización Industrial
# 	    ($auth eq "apr1.org")	or	# april.org (french something)
# 	    ($auth eq "amzn.com")	or	# Amazon.com
# 	    ($auth eq "baixa.ki")	or	# Baixa Ki, brazilian miscellanea agregator
# 	    ($auth eq "bfpne.ws")	or	# Burlington Free Press
# 	    ($auth eq "bloom.bg")	or	# Bloomberg News
# 	    ($auth eq "brook.gs")	or
# 	    ($auth eq "buswk.co")	or	# Business Week
# 	    ($auth eq "cultm.ac")	or	# Cult of Mac
# 	    ($auth eq "egent.me")	or
# 	    ($auth eq "elsab.me")	or
# # 	    ($auth eq "enwp.org")	or	# English Wikipedia. Not really worth deshortening.
# 	    ($auth eq "flpbd.it")	or  # Flipboard
# 	    ($auth eq "gizmo.do")	or	# Gizmodo
# 	    ($auth eq "linkd.in")	or	# LinkedIn
# 	    ($auth eq "l.r-g.me")	or	# Powered by bit.ly
# 	    ($auth eq "maril.in")	or	# Marilink
# 	    ($auth eq "mbist.ro")	or	# MediaBistro
# 	    ($auth eq "mcmgz.in")	or	# Mac Magazine
# 	    ($auth eq "meetu.ps")	or	($auth eq "www.meetup.com") or
# 	    ($auth eq "menea.me")	or	# Menéame
# 	    ($auth eq "mhoff.me")	or
# 	    ($auth eq "migre.me")	or
# 	    ($auth eq "mobro.co")	or	# Movember
# 	    ($auth eq "mslnk.bz")	or
# 	    ($auth eq "nokia.ly")	or
# 	    ($auth eq "on.fb.me")	or
# 	    ($auth eq "oreil.ly")	or
# 	    ($auth eq "paill.fr")	or	# Powered by bit.ly
# 	    ($auth eq "p.ost.im")	or
# 	    ($auth eq "pulse.me")	or	($auth eq "www.pulse.me")	or
# 	    ($auth eq "qwapo.es")	or
# 	    ($auth eq "rafam.co")	or
# 	    ($auth eq "refer.ly")	or
# 	    ($auth eq "ripar.in")	or	# Riparian Data
# 	    ($auth eq "secby.me")	or	# managed by bit.ly
# 	    ($auth eq "short.ie")	or
# 	    ($auth eq "short.to")	or
# 	    ($auth eq "slate.me")	or	# The Slate
# 	    ($auth eq "specc.ie")	or
# #	    ($auth eq "spoti.fi")	or	# Spotify. Not really worth deshortening as the full URL doesn't contain valuable info (track name, etc)
# 	    ($auth eq "s.shr.lc")	or	# Shareaholic, bitly-powered
# 	    ($auth eq "s.si.edu")	or	# Smithsonian
# 	    ($auth eq "s.vfs.ro")	or
# 	    ($auth eq "tbbhd.me")	or	# Powered by bit.ly
# 	    ($auth eq "tmblr.co")	or	# Tumblr
# 	    ($auth eq "thkpr.gs")	or	# ThinkProgress.org
# 	    ($auth eq "thndr.me")	or	($auth eq "www.thunderclap.it") or
# 	    ($auth eq "twurl.nl")	or
# 	    ($auth eq "ustre.am")	or
# 	    ($auth eq "w.abc.es")	or
# 	    ($auth eq "wired.uk")	or
# 	    ($auth eq "ymlp.com")	or
# #	    ($auth eq "youtu.be")	or	# This one is actually useful: no information is gained by de-shortening.
# 	    ($auth eq "1.usa.gov")	or	# USA
# 	    ($auth eq "atres.red")	or	# Atresmedia (antena 3 et al), spanish media group
# 	    ($auth eq "binged.it")	or	# Microsoft goes Bing!. Bing!
# 	    ($auth eq "bitly.com")	or
# 	    ($auth eq "drudge.tw")	or
# 	    ($auth eq "es.rt.com")	or
# 	    ($auth eq "go.shr.lc")	or	# Short shareholic
# 	    ($auth eq "interc.pt")	or
# 	    ($auth eq "keruff.it")	or
# 	    ($auth eq "mitsha.re")	or	# MIT share
# 	    ($auth eq "mklnd.com")	or
# 	    ($auth eq "mktfan.es")	or
# 	    ($auth eq "m.safe.mn")	or
# 	    ($auth eq "ondace.ro")	or
# 	    ($auth eq "onforb.es")	or	# Forbes
# 	    ($auth eq "onion.com")	or	# The Onion
# 	    ($auth eq "on.ft.com")	or
# 	    ($auth eq "on.rt.com")	or	# RT
# 	    ($auth eq "pewrsr.ch")	or
# 	    ($auth eq "pocket.co")	or	($auth eq "getpocket.com" and $path =~ m#^/s#)	or	# GetPocket, also known as ReadItLater
# 	    ($auth eq "politi.co")	or	# Politico.com newspaper
# 	    ($auth eq "s.hbr.org")	or
# 	    ($auth eq "thebea.st")	or	# The Daily Beast
# 	    ($auth eq "u.afp.com")	or
# 	    ($auth eq "urlads.co")	or
# 	    ($auth eq "washin.st")	or	# Washington institute
# 	    ($auth eq "wlstrm.me")	or	# Jeff Walstrom
# 	    ($auth eq "wwhts.com")	or  # WWWhatsNew, powered by bit.ly
# 	    ($auth eq "dnlchw.net") or
# 	    ($auth eq "eepurl.com")	or
# 	    ($auth eq "elconfi.de")	or	# El Confidencial (spanish newspaper)
# 	    ($auth eq "feedly.com")	or
# 	    ($auth eq "go.usa.gov")	or
# 	    ($auth eq "l.aunch.us")	or
# 	    ($auth eq "lifehac.kr")	or	# Lifehacker
# 	    ($auth eq "macrumo.rs")	or	# Mac Rumors
# 	    ($auth eq "mitsmr.com")	or
# 	    ($auth eq "oak.ctx.ly")	or
# 	    ($auth eq "on.io9.com")	or	# IO9
# 	    ($auth eq "on.mash.to")	or	# Mashable
# 	    ($auth eq "on.tcrn.ch")	or	# TechCrunch
# 	    ($auth eq "on.wsj.com")	or	# Wall Street Journal
# 	    ($auth eq "recode.net")	or	($auth eq "on.recode.net")	or
# 	    ($auth eq "theatln.tc")	or	# The Atlantic
# 	    ($auth eq "the-fa.com")	or	# Powered by po.st
# 	    ($auth eq "thewur.com")	or
# 	    ($auth eq "to.pbs.org")	or	# PBS
# 	    ($auth eq "tus140.com")	or
# 	    ($auth eq "dx.plos.org")	or	($auth eq "www.plosone.org")	or	# PlosOne journals
# 	    ($auth eq "esriurl.com")	or	# ESRI
# 	    ($auth eq "go.nasa.gov")	or	# NASA
# 	    ($auth eq "GovAlert.eu")	or
# 	    ($auth eq "smarturl.it")	or
# 	    ($auth eq "tinyurl.com")	or
# 	    ($auth eq "trackurl.it")	or
# 	    ($auth eq "www.ara.cat")	or
# 	    ($auth eq "hackaday.com")	or
# 	    ($auth eq "r.spruse.com")	or	# Powered by bit.ly
# 	    ($auth eq "on.natgeo.com")	or	# National Geographic
	    ($auth eq "www.meetup.com")	or	# Meetup adds some tracking crap.
# 	    ($auth eq "www.tumblr.com")	or
# 	    ($auth eq "feeds.gawker.com")	or
	    ($auth eq "cards.twitter.com")	or	# Et tu, twitter?
# 	    ($auth eq "feeds.feedburner.com")	or
	    ($auth eq "feedproxy.google.com")	or
	    ($auth eq "www.pheedcontent.com")	or	# Oh, look, Imma l337 h4xx0r. Geez.
	    ($auth eq "click.linksynergy.com")	or
	    ($auth =~ m/^news\.google\.[a-z]{2,3}$/)	or	# Hah! You thought you were going to pollute my links, did you, google news?
	    ($auth eq "www.linkedin.com" and $path eq "/slink")	or	# A tricky one. lnkd.in redirects to www.linkedin.com/slink?foo, which redirects again.
	    ($auth =~ m/^feeds\./)	or	# OK, I've had enough of you, feeds.whatever.whatever!
	    ($auth =~ m/feedsportal\.com$/)	or	# Gaaaaaaaaaaaaaaaah!
	    ($auth =~ m/^rss\./)	or	# Will this never end?
	    ($auth =~ m/^rd\.yahoo\./)	or	# Yahoo feeds... *sigh*
	    ($auth =~ m/^redirect\./)	or	# redirect.viglink.com and others
	    ($auth =~ m/^go\./)	or
	    ($auth =~ m/^ww\./)	or	# More than one spanish media company uses ww.whatever as shorteners
	    ($auth =~ m#.tuu.gs$#)	or	# whatever.tuu.gs powered by Tweet User URL
	    ($auth =~ m#.sharedby.co$#)	or	# whatever.sharedby.co
	    ($auth eq "www.google.com" and $path eq "/url")	or	# I hate it when people paste URLs from the stupid google url tracker.
	    ($auth eq "traffic.shareaholic.com")	or	# Yet another traffic counter
	    ($path =~ m#^/wf/click# )	or	# Any URL from *any* server which path starts with /wf/click?upm=foobar has been sent through SendGrid, which collects stats.
# 	    ($auth eq "www.guardian.co.uk" and $path =~ m#^/p/# )	or	# Guardian short links, e.g. http://www.guardian.co.uk/p/3fz77/tw
	    ($auth eq "www.eldiario.es" and $path =~ m#^/_# )	or	# ElDiario short links, e.g. www.eldiario.es/_1b3454af
	    ($auth eq "www.meneame.net" and $path =~ m#^/(.*\/)?go# )	or	# Menéame.net redirections (not posts, etc)
	    ($auth eq "www.stitcher.com" and $query =~ m#eid# )	or	# Stitcher podcasts if the podcast name is not shown
	    ($auth =~ m/\.link$/)	# I guess this new TLD will be mostly used for redirectors
	    )
	{
		$unshorting_method = "HEAD";	# For these servers, perform a HTTP HEAD request
	}
	elsif ($auth eq "www.snsanalytics.com")
	{
		$unshorting_method = "REGEXP";	# For these servers, fetch the page and look for a <input name='url' value='...'> field
		$unshorting_regexp = qr/<input.* name=["']url["'] .*value=["'](.*?)["'].*/;
		$unshorting_thing_were_looking_for = "<input name='url'> field";
	}
	elsif (($auth =~ m#\.visibli\.com$# and $path =~ m#^/share# ) or	# http://whatever.visibli.com/share/abc123
	       ($auth =~ m#\.visibli\.com$# and $path =~ m#^/links# )	# http://whatever.visibli.com/links/abc123
	      )
	{
		$unshorting_method = "REGEXP";	# For these servers, look for the first defined iframe
		$unshorting_regexp = qr/<iframe .*src=["'](.*?)["'].*>/;
		$unshorting_thing_were_looking_for = "iframe";
	}
	elsif (($auth eq "bota.me")     or
	       ($auth eq "op.to")       or      ($auth eq "www.op.to")
	      )
	{
		$unshorting_method = "REGEXP";	# For these servers, look for the first defined javascript snippet with "window.location=foo"
# 		$unshorting_regexp = qr/window.location\s*=\s*["'](.*?)["']\s*;/;
		$unshorting_regexp = qr/window\.location(\.href)?\s*=\s*["'](.*?)["']\s*;/;
		$unshorting_thing_were_looking_for = "window.location";
	}
	elsif (($auth eq "www.donotlink.com" ))
	{
		$unshorting_method = "REGEXP";	# For these servers, look for the first defined javascript snippet with "window.location=foo"
# 		$unshorting_regexp = qr/window.location\s*=\s*["'](.*?)["']\s*;/;
		$unshorting_regexp = qr/window\.location\.href\s*=\s*["'](.*?)["']\s*;/;
		$unshorting_thing_were_looking_for = "window.location";
	}
# 	elsif (($auth =~ m/^news\.google\.[a-z]{2,3}$/)	# For a while, Google News stopped issuing HTTP 302s.
# 	      )
# 	{
# 		$unshorting_method = "REGEXP";	# For these servers, look for the first <meta http-equiv=refresh content='0;URL=http://foobar'> tag
# 		$unshorting_regexp = qr/<meta\s*http-equiv=['"]refresh['"]\s*content=["']\d;URL=['"](.*?)["']\s*['"]\s*>;/i ;
# 		$unshorting_thing_were_looking_for = "meta refresh";
# 	}
	elsif (($auth eq "www.scoop.it" )
	      )
	{
		$unshorting_method = "REGEXP";	# For these servers, look for the first <h2 class="postTitleView"><a href=...></a> tag
		$unshorting_regexp = qr#<h2 class="postTitleView"><a href="(.*?)"# ;
# 		<h2 class="postTitleView"><a href="https://www.youtube.com/watch?v=LKtbZvWDhKk" onclick="trackPostClick(3994760072); r
		$unshorting_thing_were_looking_for = "scoop.it article";
	}
	elsif ( $extpref_deshortifyalways )
	{
		# Skip some well-known servers that are better to be left shortened.
		if (
			(not $auth =~ m#twitter\.com$#) and	# Redirects to login and so on
			(not $auth eq "youtu.be") and	# Full link doesn't add any info
			(not $auth eq "spoti.fi") and	# Full link doesn't add any info
			(not $auth eq "4sq.com") and	# Full link doesn't add any info
			(not $auth eq "flic.kr") and	# Full link doesn't add any info
			(not $auth eq "untp.beer") and	# Full link doesn't add any info
			(not $auth =~ m#blogspot.com$#) and	# blogspot.com always redirects to a nearby (geolocated) server
			(not $auth eq "www.facebook.com") and	# facebook.com will redirect any page to fb.com/unsupportedbrowser due to user-agent
			(not $auth eq "www.nytimes.com") and	# New York Times articles will only loop till a no cookies page.
			(not $auth eq "www.elmundo.es") and	# El Mundo newspaper will only timeout and waste time
			(not $auth eq "www.economist.com") and	# "You are banned from this site.  Please contact via a different client configuration if you believe that this is a mistake."
			(not $auth =~ m#"^www\.amazon\.#) and	# 405 MethodNotAllowed
			(not $auth eq "pbs.twimg.com") and	# Might trigger verbose errors if twitter is over capacity
			(not $auth eq "www.linkedin.com") and	# Redirects to login
			(not $url =~ m#subscribe#) and	# Paywall (e.g. financial times)
			(not $url =~ m#nocookie#) and
			1
			)
		{
			$unshorting_method = "HEAD";
			$unshorting_override = 1;
		}
	}

	if ($loop_detect < 1)
	{
        $unshorting_method=none;
        &$exception(33, "*** Detected deep link loop in $original_url\n");
        return &$cleanup_url($original_url);
    }


	if (not $unshorting_method eq none)
	{
		print $stdout "-- Yo, deshortening $url ($auth)\n" if ($superverbose);

		# Check the cache first.
		if ($deshortify_cache{$original_url})
		{
# 			our $deshortify_cache_hit_count;
			$store->{cache_hit_count} += 1;
			print $stdout "-- Deshortify cache hit: $url -> " . $deshortify_cache{$original_url} . " ($store->{cache_hit_count} hits)\n" if ($verbose);
			if (not $deshortify_cache{$original_url} eq $original_url)
				{ return &$unshort($deshortify_cache{$original_url}, $extpref_deshortifyretries, $loop_detect -1); }
			else
				{ &$exception(33,"-- Detected cached link loop\n"); return &$cleanup_url($original_url);
}
		}

# 		our $deshortify_cache_empty_counter;
		$store->{cache_misses} += 1;

# 		our $deshortify_cache_limit;
		if ($store->{cache_misses} >= $store->{cache_limit})
		{
# 			our $deshortify_cache_flushes;
			$store->{cache_flushes} += 1;
			$deshortify_cache = ();
			$store->{cache_misses} = 0;
			print $stdout "-- Deshortify cache flushed\n" if ($verbose)
		}


		# Get the HTTP user agent ready.
		my $ua = LWP::UserAgent->new;
		$ua->max_redirect( 0 );	# Don't redirect, just return the headers and look for a "Location:" one manually.
		$ua->agent( "oysttyer $oysttyer_VERSION URL de-shortifier (" . $ua->agent() . ") (+https://github.com/oysttyer)" ); # Be good net citizens and say how nerdy we are and that we're a bot

		if ($extpref_deshortifyproxy) {	# If there's a proxy configured in .ttytterrc, use it no matter what.
			$ua->proxy([qw/ http https /] => $extpref_deshortifyproxy);
		}
		else # If no proxy configured, try to get the one set up in the environment variables
		{
			if ( $ENV{http_proxy} ){
				$ua->proxy([qw/ http /] => $ENV{http_proxy} );
			}
			if ( $ENV{https_proxy} ){
				$ua->proxy([qw/ https /] => $ENV{https_proxy} );
			}
		}

		$ua->cookie_jar({});

		my $response;
		if ($unshorting_method eq "HEAD")
		{
			# Visit the link with a HEAD request, see if there's a redirect header. If redirected -> that's the URL we want.

			my $request  = HTTP::Request->new( HEAD => "$url" );
			$response = $ua->request($request);
		}
# 		elsif ($unshorting_method eq "REGEXP")
		else
		{
			$response = $ua->get($url);
		}

		# For either HEAD or REGEXP methods, check if we've got a 302 result with a Location: header.
		if ($response->header( "Location" ))
		{
# 			$url = $response->request->uri;
			$url = $response->header( "Location" );
			print "-- Deshortened: $original_url -> $url\n" if ($verbose);

			if ($unshorting_override)
			{
				# Analise the URLs to check that it looks like a shortener
# 				($scheme, $auth, $path, $query, $frag) = uri_split($original_url);
				($scheme_n, $auth_n, $path_n, $query_n, $frag_n) = uri_split($url);
				if (
					not ($scheme eq $scheme_n and $path eq $path_n and $query eq $query_n and $frag eq $frag_n)	# Only the server name has changed
					and not ($scheme eq $scheme_n and $auth eq $auth_n and "$path/" eq $path_n and $query eq $query_n and $frag eq $frag_n)	# A slash has been added to the path
					)
					{ print "-- New shortener found: $original_url -> $url\n"; }
				else
					{ print "-- False new shortener found: $original_url -> $url\n" if ($superverbose); }
			}

			# If my header URL starts with a "/", treat it as a relative URL.
			if ($url =~ m#^/# )
				{ $url = $scheme . "://" . $auth . $url; } # becomes http://server/$1
			$newurl =~ s/&amp;/&/;	# Maybe we should escape all HTML entities, but this should suffice.


			# Add to cache
			$deshortify_cache{$original_url} = $url;

			# Let's run the URL again - maybe this is another short link!
			if (not $url eq $original_url)
				{ return &$unshort($url, $extpref_deshortifyretries, $loop_detect -1); }
		}
		elsif (not $response->is_success)	# Not a HTTP 20X code
			{ return &$unshort_retry($url, $retries_left, $response->status_line); }

		# Once we've checked for Location: headers, check for the contents if we're using the REGEXP method )only if the document retrieval has been successful)
		elsif ($unshorting_method eq "REGEXP")
		{

# 			print $stdout $response->decoded_content if ($verbose);

			my $text = $response->decoded_content;

# 			if ($text =~ m/<iframe .*src="(.*)".*>/i or $text =~ m/<iframe .*src='(.*)'.*>/i)
			if ($text =~ m/$unshorting_regexp/ig)
			{
				my $newurl = $1;

				print $stdout "-- Deshortify found an $unshorting_thing_were_looking_for for $url, and it points to $newurl\n" if ($verbose);

				# If my iframe/javascript/whatever URL starts with a "/", treat it as a relative URL.
				if ($newurl =~ m#^/# )
					{ $newurl = $scheme . "://" . $auth . $newurl; } # becomes http://server/$1
				$newurl =~ s/&amp;/&/;	# Maybe we should escape all HTML entities, but this should suffice.

				# Add to cache
				$deshortify_cache{$original_url} = $newurl;

				# Let's run the URL again - maybe this is another short link!
				if (not $url eq $newurl)
					{ return &$unshort($newurl, $extpref_deshortifyretries, $loop_detect -1); }
			}

			# If no iframes match the regexp above, panic. But just a bit.
			print $stdout "-- Deshortify expected an $unshorting_thing_were_looking_for, but none found\n" if ($verbose);
			return $url;
		}
	}


	# Unrecognised server, or no valid response. No need for checking a condition, as a recognised server will already have returned a value.
	{
		print $stdout "-- That URL doesn't seem like it's a URL shortener, it must be the real one.\n" if ($superverbose);
        return &$cleanup_url($url);
	}

# 	print $stdout "-- $original_url de-shortened into $url\n" if ($verbose && $url != $original_url) ;

	# Hey, let's underline URLs!
	return ${UNDER} . $url . ${UNDEROFF};
};











# Deshortify URLs in both standard tweets and DMs, by hooking to both $dmhandle and $handle
$dmhandle = $handle = sub {
	our $verbose;
	our $ansi;
	my $tweet = shift;

	my $text = $tweet->{'text'};

	# Why the hell are there backslashes messing up the forward slashes in the URLs?
	# Will this break something???
	$text =~ s/\\\//\//g;

	# Yeah, a \n just before a http:// will mess things up.
	$text =~ s/\\nhttp:\/\//\\n http:\/\//g;

	# Any URIs you find, run them through unshort()...
	my $finder = URI::Find->new(sub { &$unshort($_[0], $extpref_deshortifyretries, $extpref_deshortifyloopdetect) });

	$how_many_found = $finder->find(\$text);

	print $stdout "-- $how_many_found URLs de-shortened\n" if ($superverbose);

	$tweet->{'text'} = $text;

	&defaulthandle($tweet);
	return 1;

# 	return $text;
};




# Show cache statistics. Not really useful, but hey.
$addaction = $shutdown = $heartbeat = sub {
	our $verbose;
	our $is_background;

	if ($is_background)
	{
		our $store;
		$cache_hits  = $store->{'cache_hit_count'};
		$cache_miss  = $store->{'cache_misses'} + ($store->{'cache_limit'} * $store->{'cache_flushes'} );
		$cache_flush = $store->{'cache_flushes'};
		$context = "background";
	}
	else
	{
		return 0;

# 		print "-- Fetching deshortify cache stats from background process\n" if $verbose;
# 		$cache_hits  = getbackgroundkey('cache_hit_count');
# 		$cache_miss  = getbackgroundkey('cache_misses') + (getbackgroundkey('cache_limit') * getbackgroundkey('cache_flushes') );
# 		$cache_flush = getbackgroundkey('cache_flushes');
# 		$context = "foreground";
# 		print "-- Fetched deshortify cache stats from background process\n" if $verbose;
	}

# 	$store->{deshortify_cache_misses} += ($store->{deshortify_cache_limit} * $store->{deshortify_cache_flushes});
# 	print $stdout "-- Deshortify cache stats (misses/hits/flushes): $store->{deshortify_cache_misses}/$store->{deshortify_cache_hit_count}/$store->{deshortify_cache_flushes}\n" if $verbose;
# 	sendbackgroundkey('deshortify_cache_misses', getbackgroundkey('deshortify_cache_misses') + (getbackgroundkey('deshortify_cache_limit') * getbackgroundkey('deshortify_cache_flushes'))  );

	print $stdout "-- Deshortify cache stats (hits/misses/flushes/context): $cache_hits/$cache_miss/$cache_flush/$context\n" if $verbose;

	return 0;
};










