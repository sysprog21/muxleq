
\ System Finalization
: cold [ {boot} ] literal 2* @execute ; ( -- : cold start )

t' (boot) half {boot} t!           ( Set starting Forth word )
t' quit {quit} t!                  ( Set initial Forth word )
atlast {forth-wordlist} t!         ( Make wordlist work )
{forth-wordlist} {current} t!      ( Set "current" dictionary )
there h t!                         ( Assign dictionary pointer )
local? {user}  t!                  ( Assign number of locals )
primitive t@ double mkck check t!  ( Set checksum over Forth )
atlast {last} t!                   ( Set last defined word )
save-target                        ( Output target image )
.end                               ( Return to normal Forth )
bye                                ( Exit cross-compiler )
