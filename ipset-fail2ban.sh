#!/bin/bash

###################################################################################################
# DESCRIPTION
#     Utility for creating an ipset blacklist from the output of "fail2ban-client status <jail>"
#     and adding the generated blacklist to iptables.
#
#     Configuration file is recommended for normal use. Command line options are intended mainly
#     for creating standalone blacklists for manual inspection or other uses, or for testing. If
#     command line options are given after a valid configuration file, the command line options
#     will override the value in the configuration file for that option.
#
#     If -i <ipset_blacklist> is specified, then -r <ipset_restore_file> is required, and -t
#     <ipset_tmp_blacklist> is also used, but a default value will be generated if it is not
#     explicity specified. 
#
# SYNOPSIS
#     ipset-blacklist.sh [CONFIGURATION_FILE]
#     ipset-blacklist.sh [OPTIONS]
#     ipset-blacklist.sh [CONFIGURATION_FILE] [OPTIONS]
#
# OPTIONS
#     -b, --blacklist-file <blacklist_file>
#             Banned IP addresses will be written to <blacklist_file>. If the file already
#             exists, IPs will be read from the file and added to the current list. Duplicate
#             IPs will be pruned. If not specified, banned IPs will be printed to STDOUT.
#
#     -i, --ipset-blacklist <ipset_blacklist> 
#             Name of ipset blacklist to add banned IP addresses to. 
# 
#     -j, --jail <jails>
#             Comma separated (no space) list of jails to get banned IP addresses from.
#
#     -r, --ipset-restore-file <ipset_restore_file>
#             File used for storing rules needed to update ipset blacklist.
#
#     -t, --ipset-tmp-blacklist <ipset_tmp_blacklist>
#             Temporary ipset blacklist for adding new blacklisted IP addresses. If not specified,
#             defaults to <ipset_blacklist>-tmp.
#
#     -c, --cleanup
#             Remove all banned IP addresses from each jail specified in <jails>. It should be
#             safe to set this to true as long as <blacklist_file> is written to each time and
#             saved. For jails with a large number of banned IPs, this can take a while the first
#             time it is used.
#
#     -nc, --no-cleanup
#             Do not remove banned IP addresses from fail2ban jails. This is the default action,
#             so this is generally not needed unless overriding a configuration file.
#
#     -q, --quiet
#             Do not display standard messages to STDOUT. Only error messages will still be sent.
#
###################################################################################################

# Options
BLACKLIST_FILE=""
IPSET_BLACKLIST=""
IPSET_TMP_BLACKLIST=""
IPSET_RESTORE_FILE=""
CLEANUP=false
QUIET=false
declare -a JAILS=()

# IPSet defaults
IPTABLES_IPSET_POSITION=1
HASHSIZE=16384
MAXELEM=65536

# Formatting codes
RED=`tput setaf 1`
GREEN=`tput setaf 2`
YELLOW=`tput setaf 3`
BLUE=`tput setaf 4`
MAGENTA=`tput setaf 5`
CYAN=`tput setaf 6`

BOLD=`tput bold`
RESET=`tput sgr0`

# Main
main() {
    # Parse configuration file and / or positional parameters
    if [[ -z $1 ]]; then
        printf "Error: No configuration file or options given. Use -h or --help for help.\n" >&2
        exit 1
    fi
    if [[ -f $1 && -r $1 ]]; then
        if ! source "$1"; then
            printf "Error: Unable to load configuration file $1\n"
            exit 1
        fi
        shift
    fi
    if [[ $# -gt 0 ]]; then
        get_options "$@"
    fi

    # Verify options
    verify_options

    # Create blacklist
    create_blacklist
}
    
# Get options from positional parameters
get_options() {
    # Parse otpions
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit
                ;;
            -b|--blacklist-file)
                BLACKLIST_FILE="$2"
                shift
                shift
                ;;
            -i|--ipset-blacklist)
                IPSET_BLACKLIST="$2"
                shift
                shift
                ;;
            -j|--jail)
                IFS=',' read -r -a JAILS <<< "$2"
                shift
                shift
                ;;
            -r|--ipset-restore-file)
                IPSET_RESTORE_FILE="$2"
                shift
                shift
                ;;
            -t|--ipset-tmp-blacklist)
                IPSET_TMP_BLACKLIST="$2"
                shift
                shift
                ;;
            -c|--cleanup)
                CLEANUP=true
                shift
                ;;
            -nc|--no-cleanup)
                CLEANUP=false
                shift
                ;;
            -q|--quiet)
                QUIET=true
                shift
                ;;
            *)
                printf "Error: Unrecognized option $1\n" "$1" >&2
                exit 1
                ;;
        esac
    done
}

# Verify options
verify_options() {
    # Make sure script has permission to run fail2ban-client
    fail2ban-client status &> /dev/null
    if [[ $? -ne 0 ]]; then
        printf "Error: Permission denied for 'fail2ban-client status'\n"
        exit 1
    fi
    
    # Jails must exist
    if [[ ${#JAILS[@]} -eq 0 ]]; then
        printf "No jails specified.\n" >&2
        exit 1
    fi
    
    # Make sure jails are valid
    tmp="$( fail2ban-client status | grep -oP '(Jail list:\s+\K).*')"
    IFS=', ' read -r -a f2b_jails <<< "$tmp"
    declare -a f2b_jails_sorted
    readarray -t f2b_jails_sorted < <( for a in "${f2b_jails[@]}"; do echo "$a"; done | sort )
    for jail in "${JAILS[@]}"; do
        jail_exists=false
        lo=0
        hi=$(( ${#f2b_jails_sorted[@]} - 1 ))
        while (( lo <= hi )); do
            mid=$(( (hi + lo) / 2 ))
            if [[ "$jail" < "${f2b_jails_sorted[mid]}" ]]; then
                hi=$(( mid - 1 ))
            elif [[ "$jail" > "${f2b_jails_sorted[mid]}" ]]; then
                lo=$(( mid + 1 ))
            else
                jail_exists=true
                break
            fi
        done
        if [[ ${jail_exists} == false ]]; then
            printf "Error: Could not find jail in 'fail2ban-client status': %s\n" "$jail" >&2
            exit 1
        fi
    done
    
    # Check ipset options
    if [[ -n ${IPSET_BLACKLIST} ]]; then
        if [[ -z ${IPSET_RESTORE_FILE} ]]; then
            printf "Error: <ipset_blacklist> specified, but <ipset_restore_file> missing.\n" >&2
            exit 1
        fi
        if [[ -z ${IPSET_TMP_BLACKLIST} ]]; then
            IPSET_TMP_BLACKLIST="${IPSET_BLACKLIST}-tmp"
        fi
    fi
    
    # Check BLACKLIST_FILE
    if [[ -e ${BLACKLIST_FILE} ]]; then
        if [[ ! -f ${BLACKLIST_FILE} ]]; then
            printf "Error: Invalid file %s\n" "${BLACKLIST_FILE}" >&2
            exit 1
        elif [[ ! -r ${BLACKLIST_FILE} ]]; then
            printf "Error: Unable to read %s\n" "${BLACKLIST_FILE}" >&2
            exit 1
        elif [[ ! -w ${BLACKLIST_FILE} ]]; then
            printf "Error: Unable to write to %s\n" "${BLACKLIST_FILE}" >&2
            exit 1
        fi
    elif [[ -n ${BLACKLIST_FILE} ]]; then
        touch "${BLACKLIST_FILE}" &> /dev/null
        if [[ $? -ne 0 ]]; then
            printf "Error: Unable to create %s\n" "${BLACKLIST_FILE}" >&2
            exit 1
        fi
    fi
    
    # Check IPSET_RESTORE_FILE
    if [[ -n ${IPSET_RESTORE_FILE} ]]; then
        touch "${IPSET_RESTORE_FILE}" &> /dev/null
        if [[ $? -ne 0 ]]; then
            printf "Error: Unable to write to %s\n" "${IPSET_RESTORE_FILE}" >&2
            exit 1
        fi
    fi

}

# Create blacklist
create_blacklist() {
    ! ${QUIET} && printf "Gathering banned IP addresses...\n"
    
    # Get IPs from existing BLACKLIST_FILE
    ips_all=""
    if [[ -r ${BLACKLIST_FILE} && -s ${BLACKLIST_FILE} ]]; then
        ips_all="$( grep -Po '(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?' "${BLACKLIST_FILE}" )"
        [[ -z ${ips_all} ]] && num_file=0 || num_file="$( wc -l <<< "$ips_all" )"
        ! ${QUIET} && printf "    + ${YELLOW}${BOLD}%6s${RESET} IPs from ${YELLOW}${BOLD}%s${RESET}\n" "$num_file" "${BLACKLIST_FILE}"
    fi
    
    # Get IPs
    declare -A ips_jails
    for jail in "${JAILS[@]}"; do
        ips_jails[$jail]="$( fail2ban-client status "$jail" | grep -oP '(Banned IP list:\s+\K).*' | sed -E -e 's/[[:blank:]]+/\n/g' )"
        if [[ -n ${ips_all} ]]; then
            [[ -n "${ips_jails[$jail]}" ]] && printf -v ips_all "%s\n%s" "$ips_all" "${ips_jails[$jail]}"
        else
            [[ -n "${ips_jails[$jail]}" ]] && ips_all="${ips_jails[$jail]}"
        fi
        [[ -z ${ips_jails[$jail]} ]] && num_jail=0 || num_jail="$( wc -l <<< "${ips_jails[$jail]}" )"
        ! ${QUIET} && printf "    + ${BOLD}%6s${RESET} IPs from ${BOLD}%s${RESET}\n" "$num_jail" "$jail"
    done

    # Remove private IPs and duplicates
    ips_all_unique="$( sed -r -e '/^(0\.0\.0\.0|10\.|127\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.|192\.168\.|22[4-9]\.|23[0-9]\.)/d' <<< "$ips_all" | sort -n | sort -mu )"
    [[ -z ${ips_all} ]] && num_total=0 || num_total="$( wc -l <<< "$ips_all" )"
    [[ -z ${ips_all_unique} ]] && num_unique=0 || num_unique="$( wc -l <<< "$ips_all_unique" )"
    num_dupe="$(( num_total - num_unique ))"
    ! ${QUIET} && printf "    - ${MAGENTA}${BOLD}%6s${RESET} duplicate/private IPs removed\n" "$num_dupe"
    ! ${QUIET} && printf "    = ${GREEN}${BOLD}%6s${RESET} unique banned IPs\n\n" "$num_unique"
    
    # Write to file
    if [[ -n ${BLACKLIST_FILE} ]]; then
        ! ${QUIET} && printf "Writing ${GREEN}${BOLD}%s${RESET} unique IP addresses to ${YELLOW}${BOLD}%s${RESET}...\n" "$num_unique" "${BLACKLIST_FILE}"
        printf "$ips_all_unique" > "${BLACKLIST_FILE}"
    else
        ! ${QUIET} && [[ -n ${ips_all_unique} ]] && printf "%s\n" "$ips_all_unique"
    fi

    # If ipset parameter not set, we are done
    if [[ -z ${IPSET_BLACKLIST} ]]; then
        exit
    fi

    # Create ipset blacklist
    ipset list -n | grep -q "${IPSET_BLACKLIST}" &> /dev/null
    if [[ $? -ne 0 ]]; then
        create_blacklist="ipset create ${IPSET_BLACKLIST} -exist hash:net family inet hashsize ${HASHSIZE} maxelem ${MAXELEM}"
        ! ${QUIET} && printf "Creating ipset blacklist ${YELLOW}${BOLD}%s${RESET}...\n" "${IPSET_BLACKLIST}"
        ! ${QUIET} && printf "    > %s\n" "$create_blacklist"
        eval ${create_blacklist}
        if [[ $? -ne 0 ]]; then
            printf "Error: Unable to create blacklist %s\n" "${IPSET_BLACKLIST}"
            exit 1
        fi
        ! ${QUIET} && printf "    > OK\n"
    fi
    
    # Add ipset blacklist rule to iptables
    iptables -nvL INPUT | grep -q "match-set ${IPSET_BLACKLIST}" &> /dev/null
    if [[ $? -ne 0 ]]; then
        create_rule="iptables -I INPUT "${IPTABLES_IPSET_POSITION:-1}" -m set --match-set "${IPSET_BLACKLIST}" src -j DROP"
        ! ${QUIET} && printf "Creating iptables rule for ipset blacklist ${YELLOW}${BOLD}%s${RESET}...\n" "${IPSET_BLACKLIST}"
        ! ${QUIET} && printf "    > %s\n" "$create_rule"
        eval ${create_rule}
        if [[ $? -ne 0 ]]; then
            printf "Error: Unable to create iptables rule for --match-set %s\n" "${IPSET_BLACKLIST}"
            exit 1
        fi
        ! ${QUIET} && printf "    > OK\n"
    fi
    
    # Create ipset blacklist restore file
    ! ${QUIET} && printf "Creating ipset restore file ${YELLOW}${BOLD}%s${RESET}...\n" "${IPSET_RESTORE_FILE}"
    create_blacklist="create ${IPSET_BLACKLIST} -exist hash:net family inet hashsize ${HASHSIZE} maxelem ${MAXELEM}"
    create_tmp_blacklist="create ${IPSET_TMP_BLACKLIST} -exist hash:net family inet hashsize ${HASHSIZE} maxelem ${MAXELEM}"
    printf "%s\n%s\n" "$create_blacklist" "$create_tmp_blacklist" > ${IPSET_RESTORE_FILE}
    sed -rn -e '/^#|^$/d' -e "s/^([0-9./]+).*/add "${IPSET_TMP_BLACKLIST}" \1/p" <<< "$ips_all_unique" >> ${IPSET_RESTORE_FILE}
    printf "swap %s %s\n" "${IPSET_BLACKLIST}" "${IPSET_TMP_BLACKLIST}" >> ${IPSET_RESTORE_FILE}
    printf "destroy %s\n" "${IPSET_TMP_BLACKLIST}" >> ${IPSET_RESTORE_FILE}
    
    # Restore blacklist
    restore_blacklist="ipset -file "${IPSET_RESTORE_FILE}" restore"
    ! ${QUIET} && printf "Restoring ipset blacklist ${YELLOW}${BOLD}%s${RESET}...\n" "${IPSET_BLACKLIST}"
    ! ${QUIET} && printf "    > %s\n" "$restore_blacklist"
    eval ${restore_blacklist}
    if [[ $? -ne 0 ]]; then
        printf "Error: Unable to restore blacklist from ipset restore file %s\n" "${IPSET_RESTORE_FILE}"
        exit 1
    fi
    ! ${QUIET} && printf "    > OK\n"
    
    # Cleanup fail2ban jails
    if [[ ${CLEANUP} == true && -n ${ips_all_unique} ]]; then
        for jail in "${JAILS[@]}"; do
            [[ -z ${ips_jails[$jail]} ]] && num_jail=0 || num_jail="$( wc -l <<< "${ips_jails[$jail]}" )"
            ! ${QUIET} && printf "Removing %s banned IPs from fail2ban jail ${YELLOW}${BOLD}%s${RESET}...\n" "$num_jail" "$jail"
            while IFS="" read -r ip || [[ -n "$ip" ]]; do
                if [[ -z ${ip} ]]; then
                    continue
                fi
                f2b_unbanip="fail2ban-client set "${jail}" unbanip "${ip}""
                ! ${QUIET} && printf "    > %s\n" "$f2b_unbanip"
                eval ${f2b_unbanip} &> /dev/null
                if [[ $? -ne 0 ]]; then
                    printf "Warning: Unable to unban ip %s from fail2ban jail %s\n" "$ip" "$jail"
                fi
            done <<< "${ips_jails[$jail]}"
        done
    fi

    ! ${QUIET} && printf "Total number of IP addresses in blacklist: ${BOLD}%s${RESET}\n" "$num_unique"
}

# Show help
show_help() {
    docstring=$( grep -ozP "#{10,}(.|\n)*#{10,}" ${0} | sed -e 's/^# //g' -e 's/#//g' )
    regex="^(\s*)(-.+, --[^[:space:]]+)(.*)$"
    while IFS='' read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "DESCRIPTION"* ]]; then
            printf "${BOLD}DESCRIPTION${RESET}\n"
        elif [[ "$line" == "OPTIONS"* ]]; then
            printf "${BOLD}OPTIONS${RESET}\n"
        elif [[ "$line" == "SYNOPSIS"* ]]; then
            printf "${BOLD}SYNOPSIS${RESET}\n"
        elif [[ "$line" =~ $regex ]]; then
            printf "%s${BOLD}%s${RESET}%s\n" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
        else
            printf "%s\n" "$line"
        fi
    done <<< "$docstring"
    printf "\n"
}

main "$@"
