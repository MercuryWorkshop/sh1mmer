document.querySelectorAll('u').forEach(elem=>{
  elem.onclick=function(){
    alert(this.message)
  }
})
