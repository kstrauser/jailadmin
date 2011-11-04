# $Id: Makefile 139 2004-11-19 21:05:01Z kirk $

MAJOR=	1
MINOR=	8
PROGRAMNAME=	jailadmin
DISTNAME=	${PROGRAMNAME}-${MAJOR}.${MINOR}
PERLVER=	5.8.5
SITEPERLDIR=	/usr/local/lib/perl5/site_perl/${PERLVER}
PREFIX=		/usr/local

all:

tarball:
	mkdir ${DISTNAME}
	xargs < tarfiles -I{} cp {} ${DISTNAME}/
	tar cvzf ${DISTNAME}.tar.gz ${DISTNAME}
	rm -rf ${DISTNAME}

install: installbase installsnmp

installbase:
	@echo 'Installing the main jailadmin files'
	install jail.sh ${PREFIX}/etc/rc.d/zzz-jail.sh
	install jailadmin.conf.sample ${PREFIX}/etc
	install Jail.pm ${SITEPERLDIR}
	install jailadmin ${PREFIX}/sbin
	install -d ${PREFIX}/share/doc/${PROGRAMNAME}
	install INSTALL ${PREFIX}/share/doc/${PROGRAMNAME}
	install README ${PREFIX}/share/doc/${PROGRAMNAME}

installsnmp:
	@echo 'Installing the jailadmin SNMP files'
	install jail-snmp ${PREFIX}/sbin
	install jail-snmp-persist ${PREFIX}/sbin
	install JAIL-MIB.txt ${PREFIX}/share/snmp/mibs

deinstall:
	rm ${PREFIX}/etc/rc.d/zzz-jail.sh
	rm ${PREFIX}/etc/jailadmin.conf.sample
	rm ${SITEPERLDIR}/Jail.pm
	rm ${PREFIX}/sbin/jail-snmp
	rm ${PREFIX}/sbin/jail-snmp-persist
	rm ${PREFIX}/sbin/jailadmin
	rm ${PREFIX}/share/snmp/mibs/JAIL-MIB.txt
	rm -rf ${PREFIX}/share/doc/${PROGRAMNAME}

