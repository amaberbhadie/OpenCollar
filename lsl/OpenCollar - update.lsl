//Licensed under the GPLv2, with the additional requirement that these scripts
//remain "full perms" in Second Life.  See "OpenCollar License" for details.

// This script does 4 things:
// 1 - On rez, check whether there's an update to the collar available.
// 2 - On command, ask appengine for an updater to be delivered.
// 3 - On command, do the handshaking necessary for updater object to install
// its shim script.
// 4 - On rez, check a file on Github for any important project news, and
// announce it to the wearer if it's new.  The timestamp of the last news
// report is remembered in the object desc.

// NOTE: As of version 3.706, the update script no longer uses object name or
// description to tell it the current collar version.  Instead, it looks in the
// "~version" notecard.  It compares the contents of that notecard with the
// text at https://raw.github.com/nirea/ocupdater/release/lsl/~version.  If the
// version online is newer, then the wearer will be advised that an update is
// available.

// Update checking sequence:
// 1 - On rez, reset script.
// 2 - On start, read the version notecard.
// 3 - On getting version notecard contents, store in global var and request
// version from github.
// 4 - On getting version from github, compare to version from notecard.
// 5 - If github version is newer, then give option to have update delivered.
// 6 - On getting command to deliver updater, send http request to
// update.mycollar.org.

key wearer;

integer COMMAND_NOAUTH = 0;
integer COMMAND_OWNER = 500;
integer COMMAND_WEARER = 503;
integer HTTPDB_SAVE = 2000;
integer HTTPDB_REQUEST = 2001;
integer HTTPDB_RESPONSE = 2002;
integer HTTPDB_DELETE = 2003;
integer HTTPDB_EMPTY = 2004;

integer MENUNAME_REQUEST = 3000;
integer MENUNAME_RESPONSE = 3001;
integer SUBMENU = 3002;
integer UPDATE = 10001;

integer DIALOG = -9000;
integer DIALOG_RESPONSE = -9001;
integer DIALOG_TIMEOUT = -9002;

string PARENT_MENU = "Help/Debug";
string BTN_DO_UPDATE = "Update";
string BTN_GET_UPDATE = "Get Update";
string BTN_GET_VERSION = "Get Version";

key g_kMenuID;

integer g_iUpdateChan = -7483214;
integer g_iUpdateHandle;

key g_kConfirmUpdate;
key g_kUpdaterOrb;

// We check for the latest version number by looking at the "~version" notecard
// inside the 'release' branch of the collar's Github repo.
string version_check_url = "https://raw.github.com/nirea/ocupdater/release/lsl/~version";
key github_version_request;

// A request to this URL will trigger delivery of an updater.  We omit the
// "version=blah" parameter because we don't want the server deciding whether
// we should get an updater or not.  We just want one.
string delivery_url = "http://update.mycollar.org/updater/check?object=OpenCollarUpdater&update=yes";
key appengine_delivery_request;

// The news system is back!  Only smarter this time.  News will be kept in a
// static file on Github to keep server load down.  This script will remember
// the date of the last time it reported news so it will only show things once.
// It will also not show things more than a week old.
string news_url = "https://raw.github.com/nirea/ocupdater/master/news.md";
key news_request;

// store versions as strings and don't cast to float until the last minute.
// This ensures that we can display them in a nice way without a bunch of
// floating point garbage on the end.
string my_version = "0.0";
key my_version_request;

key g_kUpdater; // key of avi who asked for the update
integer g_iUpdatersNearBy = -1;
integer g_iWillingUpdaters = -1;

//should the menu pop up again?
integer g_iRemenu = FALSE;

Debug(string sMessage)
{
    //llOwnerSay(llGetScriptName() + ": " + sMessage);
}


key ShortKey()
{//just pick 8 random hex digits and pad the rest with 0.  Good enough for dialog uniqueness.
    string sChars = "0123456789abcdef";
    string sOut;
    integer n;
    for (n = 0; n < 8; n++)
    {
        integer iIndex = (integer)llFrand(16);//yes this is correct; an integer cast rounds towards 0.  See the llFrand wiki entry.
        sOut += llGetSubString(sChars, iIndex, iIndex);
    }

    return (key)(sOut + "-0000-0000-0000-000000000000");
}

key Dialog(key kRCPT, string sPrompt, list lChoices, list lUtilityButtons, integer iPage)
{
    key kID = ShortKey();
    llMessageLinked(LINK_SET, DIALOG, (string)kRCPT + "|" + sPrompt + "|" + (string)iPage + "|" + llDumpList2String(lChoices, "`") + "|" + llDumpList2String(lUtilityButtons, "`"), kID);
    return kID;
}

Notify(key kID, string sMsg, integer iAlsoNotifyWearer)
{
    if (kID == wearer)
    {
        llOwnerSay(sMsg);
    }
    else
    {
        llInstantMessage(kID,sMsg);
        if (iAlsoNotifyWearer)
        {
            llOwnerSay(sMsg);
        }
    }
}

ConfirmUpdate(key kUpdater)
{
    string sPrompt = "Do you want to update with " + llKey2Name(kUpdater) + " with object key:" + (string)kUpdater +"\n"
    + "Do not rez any items till the update has started.";
    g_kConfirmUpdate = Dialog(wearer, sPrompt, ["Yes", "No"], [], 0);
}

integer IsOpenCollarScript(string sName)
{
    if (llList2String(llParseString2List(sName, [" - "], []), 0) == "OpenCollar")
    {
        return TRUE;
    }
    return FALSE;
}

CheckForUpdate()
{
    Debug("checking for update");
    github_version_request = llHTTPRequest(version_check_url, [HTTP_METHOD, "GET"], "");
}

SayUpdatePin(key orb)
{
    integer pin = (integer)llFrand(99999998.0) + 1; //set a random pin
    llSetRemoteScriptAccessPin(pin);
    llRegionSayTo(orb, g_iUpdateChan, "ready|" + (string)pin ); //give the ok to send update sripts etc...
}

string LeftOfDecimal(string str) {
    integer idx = llSubStringIndex(str, ".");
    if (idx == -1) {
        return str;
    }
    return llGetSubString(str, 0, idx - 1);
}

string RightOfDecimal(string str) {
    integer idx = llSubStringIndex(str, ".");
    if (idx == -1) {
        return str;
    }
    return llGetSubString(str, idx + 1, -1);
}

// LSL is fucking borked.  Example:
// llOwnerSay((string)((float)((integer)"20111011"))); chats out
// "20111012.000000", (adding 1), except sometimes when it chats out
// "20111010.000000"  (subtracting 1).  So to work around that we have this
// function that takes two string-formatted floats and tells you whether the
// second is bigger than the first.
integer SecondStringBigger(string s1, string s2) {
    // first compare the pre-decimal parts.
    integer i1 = (integer)LeftOfDecimal(s1);
    integer i2 = (integer)LeftOfDecimal(s2);

    if (i2 == i1) {
        // pre-decimal parts are the same.  Need to compare the bits after.
        integer j1 = (integer)RightOfDecimal(s1);
        integer j2 = (integer)RightOfDecimal(s2);
        return j2 > j1;
    } else {
        return i2 > i1;
    }
}

default
{
    state_entry()
    {
        Debug("state default");

        //check if we're in an updater.  if so, then just shut self down and
        //don't do regular startup routine.
        if (llSubStringIndex(llGetObjectName(), "Updater") != -1) {
            llSetScriptState(llGetScriptName(), FALSE);
        }

        // we just started up.  Remember owner.
        wearer = llGetOwner();

        // check if we're current version or not by reading notecard.
        my_version_request = llGetNotecardLine("~version", 0); 
        
        // check for news
        news_request = llHTTPRequest(news_url, [HTTP_METHOD, "GET"], "");

        // register menu buttons
        llMessageLinked(LINK_SET, MENUNAME_RESPONSE, PARENT_MENU + "|" + BTN_DO_UPDATE, NULL_KEY);
        llMessageLinked(LINK_SET, MENUNAME_RESPONSE, PARENT_MENU + "|" + BTN_GET_UPDATE, NULL_KEY);
        llMessageLinked(LINK_SET, MENUNAME_RESPONSE, PARENT_MENU + "|" + BTN_GET_VERSION, NULL_KEY);
    }

    dataserver(key id, string data) {
        if (id == my_version_request) {
            // we only ever read one notecard ("~version"), and it only ever has
            // one line.  So whatever we got back, that's our version.
            my_version = data;        
    
            // now request the version from github.
            CheckForUpdate();            
        }
    }

    http_response(key id, integer status, list meta, string body) {
        // if we just got version information from github, then compare to what
        // we have in notecard.
        if (status == 200) { // be silent on failures.
            if (id == github_version_request) {
                // strip the newline off the end of the text
                string release_version = llGetSubString(body, 0, -2);
                if ((float)release_version > (float)my_version) {
                    g_kMenuID = Dialog(wearer, "\nOpenCollar " + release_version + " is available.  You are running version " + my_version + ".", [BTN_GET_UPDATE], ["Cancel"], 0);
                }
            } else if (id == appengine_delivery_request) {
                llOwnerSay("An updater will be delivered to you shortly.");
            } else if (id == news_request) {
                // We got a response back from the news page on Github.  See if
                // it's new enough to report to the user.
                string firstline = llList2String(llParseString2List(body, ["\n"], []), 0);
                list firstline_parts = llParseString2List(firstline, [" "], []);
                
                // The first line of a news item should always look like this:
                // # First News - 20111012 
                // So we can compare timestamps that way.  
                string this_news_time = llList2String(firstline_parts, -1);
                
                // last news time should be recorded in the prim desc, where we
                // used to record collar version.
                list descparts = llParseString2List(llGetObjectDesc(), ["~"],[]);
                string last_news_time = llList2String(descparts, 1);

                if (SecondStringBigger(last_news_time, this_news_time)) {
                    // write the new news check time to the desc.
                    // account for previously-empty descs by making sure
                    // descparts has at least 2 elements
                    if (llGetListLength(descparts) < 2) {
                        descparts = ["X"] + descparts;
                    }
                    descparts = llListReplaceList(descparts, [this_news_time], 1, 1);
                    string newdesc = llDumpList2String(descparts, "~");
                    llSetObjectDesc(newdesc);

                    string news = "OPENCOLLAR NEWS\n" + body;
                    Notify(llGetOwner(), news, FALSE);
                } 
            }
        }
    }

    on_rez(integer param) {
        llResetScript();
    }

    link_message(integer sender, integer num, string str, key id ) {
        // handle menu clicks
        if (num == SUBMENU) {
            if (str == BTN_DO_UPDATE) {
                g_iRemenu = TRUE;
                llMessageLinked(LINK_THIS, COMMAND_NOAUTH, "update", id);
            } else if (str == BTN_GET_UPDATE) {
                if (id == wearer) {
                    appengine_delivery_request = llHTTPRequest(delivery_url, [HTTP_METHOD, "GET"], "");
                } else {
                    Notify(id,"Only the wearer can request updates for the collar.",FALSE);
                }
            } else if (str == BTN_GET_VERSION) {
                // on clicking version button, send link message to self with
                // chat command
                llMessageLinked(LINK_SET, COMMAND_NOAUTH, "version remenu", id);
            }
        } else if (num >= COMMAND_OWNER && num <= COMMAND_WEARER) {
            list cmd_parts = llParseString2List(str, [" "], []);
            if (str == "update") {
                if (id == wearer) {
                    if (llGetAttached()) {
                        if (g_iRemenu) llMessageLinked(LINK_ROOT, SUBMENU, PARENT_MENU, id);
                        g_iRemenu = FALSE;
                        Notify(id, "Sorry, the collar cannot be updated while attached.  Rez it on the ground and try again.",FALSE);
                    } else {
                        string sVersion = llList2String(llParseString2List(llGetObjectDesc(), ["~"], []), 1);
                        g_iUpdatersNearBy = 0;
                        g_iWillingUpdaters = 0;
                        g_kUpdater = id;
                        Notify(id,"Searching for nearby updater",FALSE);
                        g_iUpdateHandle = llListen(g_iUpdateChan, "", "", "");
                        llWhisper(g_iUpdateChan, "UPDATE|" + sVersion);
                        llSetTimerEvent(10.0); //set a timer to close the g_iListener if no response
                    }
                } else {
                    if (g_iRemenu) llMessageLinked(LINK_ROOT, SUBMENU, PARENT_MENU, id);
                    g_iRemenu = FALSE;
                    Notify(id,"Only the wearer can update the collar.",FALSE);
                }
            } else if (llList2String(cmd_parts, 0) == "version") {
                Notify(id, "I am running OpenCollar version " + my_version, FALSE);
                if (llList2String(cmd_parts, 1) == "remenu") {
                    llMessageLinked(LINK_SET, SUBMENU, PARENT_MENU, id);
                }
            }
        }
        else if (num == MENUNAME_REQUEST)
        {
            if (str == PARENT_MENU)
            {
                llMessageLinked(LINK_SET, MENUNAME_RESPONSE, PARENT_MENU + "|" + BTN_DO_UPDATE, NULL_KEY);
                llMessageLinked(LINK_SET, MENUNAME_RESPONSE, PARENT_MENU + "|" + BTN_GET_UPDATE, NULL_KEY);
                llMessageLinked(LINK_SET, MENUNAME_RESPONSE, PARENT_MENU + "|" + BTN_GET_VERSION, NULL_KEY);
            }
        }
        else if (num == DIALOG_RESPONSE)
        {
            if (id == g_kMenuID)
            {
                //got a menu response meant for us.  pull out values
                list lMenuParams = llParseString2List(str, ["|"], []);
                key kAv = (key)llList2String(lMenuParams, 0);
                string sMessage = llList2String(lMenuParams, 1);
                integer iPage = (integer)llList2String(lMenuParams, 2);

                if (sMessage == BTN_GET_UPDATE)
                {
                    appengine_delivery_request = llHTTPRequest(delivery_url, [HTTP_METHOD, "GET"], "");
                }
            }
            else if (id == g_kConfirmUpdate)
            {
                // User clicked the Yes I Want To Update button
                list lMenuParams = llParseString2List(str, ["|"], []);
                key kAv = (key)llList2String(lMenuParams, 0);
                string sMessage = llList2String(lMenuParams, 1);
                integer iPage = (integer)llList2String(lMenuParams, 2);
                if (sMessage == "Yes")
                {
                    SayUpdatePin(g_kUpdaterOrb);
                }
            }
        }
    }

    listen(integer channel, string name, key id, string message)
    {   //collar and updater have to have the same Owner else do nothing!
        Debug(message);
        if (llGetOwnerKey(id) == wearer)
        {
            list lTemp = llParseString2List(message, [","],[]);
            string sCommand = llList2String(lTemp, 0);
            if(message == "nothing to update")
            {
                g_iUpdatersNearBy++;
            }
            else if( message == "get ready")
            {
                g_iUpdatersNearBy++;
                g_iWillingUpdaters++;
                g_kUpdaterOrb = id;
                ConfirmUpdate(g_kUpdaterOrb); 
                g_iUpdatersNearBy = -1;
                g_iWillingUpdaters = -1;
                llSetTimerEvent(0);
            }
        }
    }

    timer()
    {
        Debug("timer");
        llSetTimerEvent(0.0);
        llListenRemove(g_iUpdateHandle);
        if (g_iUpdatersNearBy > -1) {
            if (!g_iUpdatersNearBy) {
                Notify(g_kUpdater,"No updaters found.  Please rez an updater within 10m and try again",FALSE);
            } else if (g_iWillingUpdaters > 1) {
                    Notify(g_kUpdater,"Multiple updaters were found within 10m.  Please remove all but one and try again",FALSE);
            }
            g_iUpdatersNearBy = -1;
            g_iWillingUpdaters = -1;
        }
    }
}
