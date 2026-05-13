DNS SecretChip Blacklists

This repository provides daily-updated blacklists of domains and IP addresses curated for DNS-level blocking of malicious or unwanted content. The lists include known ad, tracker, and malicious domains, as well as associated IP addresses. When used by a DNS server or network filter, these lists prevent devices from resolving and connecting to those sites. In other words, any DNS lookup for a listed domain returns a “blocked” response (such as NXDOMAIN or 0.0.0.0), so requests never reach the undesired host. This approach has been widely adopted to stop spam, ads, trackers and malware at the network level.

These blacklists originate from and are used by the dns.secretchip.net service. The GitHub repository mirrors those lists in plain text, so they can be easily fetched and integrated into your own DNS setup. Because new malicious sites appear all the time, the lists are updated daily with fresh data. Users of this repo should update their copy often (e.g. via a daily cron job or automatic sync) to stay protected against the latest threats.

Features

Domains and IPs: Contains separate lists of hostnames (domains) and IP addresses to block. Domain lists cover known ad, tracker, malware, phishing, and other unwanted sites; IP lists cover individual addresses used by such services.

DNS-level blocking: Designed to be used with DNS filters or local DNS servers. When a device on your network looks up a blocked domain, the DNS server will return a safe answer (commonly 0.0.0.0 or NXDOMAIN), effectively stopping the connection. This blocks content before it even loads, without needing browser plugins.

Wildcards and subdomains: Domain lists support wildcard-style blocking (e.g. blocking example.com also blocks *.example.com), covering entire subtrees of domains with a single entry. This simplifies blocking of large trackers or ad networks.

Daily updates: The lists are refreshed every 24 hours, ensuring new threats are caught quickly. Frequent updates are important because many blocklists become stale otherwise. Users should configure periodic updates (for example, via a cron job) to fetch the newest lists.

Usage

These blacklists can be plugged into any DNS server or network filter that supports hostname type list-based blocking.

License

This project is distributed under the GNU General Public License v3.0 (GPL-3.0). The GPL-3.0 is a free copyleft license that guarantees users the freedom to use, share, and modify the lists, as long as derived work is also shared under the same terms. In short, you are free to integrate these blacklist files into your projects, but any distributed modifications must remain GPL-3.0.

For full license text, see GPL-3.0 full text or the LICENSE file in this repository.

Contributing & Support

Community contributions are welcome! If you discover a malicious domain or IP that is not yet on the list, you can suggest it via an issue or pull request on this GitHub repo. Likewise, if you find false positives (safe sites being blocked), please let us know so we can review and adjust. We encourage users to help keep the lists accurate and up-to-date. For help or feedback, please use the issue tracker or contact the maintainers.

References: This README follows practices from public DNS-blocking documentation. The GPL-3.0 license is documented by the GNU project. The lists themselves reflect information originally published at dns.secretchip.net.