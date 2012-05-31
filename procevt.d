#!/usr/sbin/dtrace -s
/*
 * procevt.d	Process creation/destruction as an evt trace.
 *
 * SEE ALSO: evtchart.pl
 */

#pragma D option quiet
#pragma D option switchrate=10

string name[int];

dtrace:::BEGIN
{
	printf("TIME(ns) EVENT ID ID_NAME PARENT_ID EXTRAS\n");
}

proc:::create
{
	printf("%d start %d %s %d\n", timestamp, args[0]->pr_pid, execname,
	    pid);
}

proc:::exec-success
{
	/* for multiple exec()s, report each execname separated by "->" */
	name[pid] = name[pid] == NULL ? execname :
	    strjoin(name[pid], strjoin("->", execname));
	printf("%d change %d %s %d\n", timestamp, pid, name[pid], ppid);
}

proc:::exit
{
	printf("%d end %d %s %d\n", timestamp, pid, execname, ppid);
	name[pid] = 0;
}
