<#-- 관리자 화면에서 공통으로 쓰는 표시용 헬퍼 -->
<#function statusLabel status>
    <#if status == 'PAID'>
        <#return '결제완료'>
    <#elseif status == 'CANCELED'>
        <#return '환불완료'>
    <#else>
        <#return '결제대기'>
    </#if>
</#function>

<#function statusClass status>
    <#if status == 'PAID'>
        <#return 'status-paid'>
    <#elseif status == 'CANCELED'>
        <#return 'status-canceled'>
    <#else>
        <#return 'status-ready'>
    </#if>
</#function>
