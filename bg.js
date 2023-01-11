window.dataLayer = window.dataLayer || [];
function gtag() { dataLayer.push(arguments); }
gtag('js', new Date());

gtag('config', 'G-MT82HHR67Y');
window.onload = () => {
    let scrollX = 0;

    setInterval(() => {
        scrollX += 1;
        if (scrollX > 2300) scrollX = 0;
        // console.log(scrollX);
        document.querySelector(".header").style = `background-position: -${scrollX}px bottom;`;
    }, 75);
}